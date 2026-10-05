package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/glusman-team/edge-linkouts/cli/internal/codec"
	"github.com/glusman-team/edge-linkouts/cli/internal/cosmos"
	"github.com/glusman-team/edge-linkouts/cli/internal/pipeline"
	"github.com/glusman-team/edge-linkouts/cli/internal/ratelimit"
	"github.com/glusman-team/edge-linkouts/cli/internal/version"
)

type statusFlags struct {
	dict       string
	checkPools bool
}

func newStatusCmd(g *globals) *cobra.Command {
	f := &statusFlags{}
	cmd := &cobra.Command{
		Use:   "status",
		Short: "Report what the store holds and what it is configured to cost",
		Long: `status answers "is my data actually in there, and what does it cost" without opening the
portal.

It reads the container's own metadata — document count, storage usage, partition key and indexing
policy — then point-reads the pool index to list every knowledge graph and release that has a
random pool, with the edge count and sample size each one carries. Both are cheap: a metadata read
and one small point read.

--check-pools additionally point-reads each pool document and reports its stored size, which is
what a random pick in that release costs in RU (Cosmos charges a point read by item size). That is
one read per release, so it is opt-in.

Indexing is expected to report "none". This app only ever point-reads by id, and an index would
add 10-20% to stored size plus write RU on every document for queries nobody issues; a portal
showing zero index storage is the configuration working, not data missing. What does mean data is
missing is a zero document count: loads run with --store file: never reach the cloud account.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runStatus(cmd.Context(), g, f)
		},
	}
	cmd.Flags().StringVar(&f.dict, "dict", "", "trained zstd dictionary the blobs were written with")
	cmd.Flags().BoolVar(&f.checkPools, "check-pools", false, "point-read every pool and report its stored size")
	return cmd
}

func runStatus(ctx context.Context, g *globals, f *statusFlags) (err error) {
	cfg, err := g.resolve()
	if err != nil {
		return err
	}
	dict, err := readDict(f.dict)
	if err != nil {
		return err
	}
	budget := ratelimit.New(cfg.RUps)
	store, err := g.openStore(cfg, budget)
	if err != nil {
		return err
	}
	defer deferClose(store.Close, &err)

	stats, err := store.Stats(ctx)
	if err != nil {
		return fmt.Errorf("read container metadata: %w", err)
	}
	printf("store: %s\n", store.Name())
	if stats.Container != "" {
		printf("container: %s\n", stats.Container)
		if strings.Contains(stats.Container, "indexing none") {
			println("  indexing none is correct here: every read is a point read by id, so index")
			println("  storage of zero in the portal is the configuration working, not missing data.")
		}
	}
	if stats.Items >= 0 {
		printf("documents: %d\n", stats.Items)
	} else {
		println("documents: not reported by this backend")
	}
	for _, line := range []struct{ label, value string }{
		{"usage", stats.Usage}, {"quota", stats.Quota},
	} {
		if line.value != "" {
			printf("%s: %s\n", line.label, line.value)
		}
	}

	index, err := pipeline.ReadPoolIndex(ctx, store, dict)
	switch {
	case errors.Is(err, cosmos.ErrNotFound):
		println("pool index: absent")
		if stats.Items > 0 {
			printf("  %d documents are stored but there is no pool index, so /random has nothing to\n", stats.Items)
			println("  pick from. Documents loaded by an older CLI look like this: reload them.")
		} else {
			println("  nothing has been loaded into this store. `linkouts load` writes it, and")
			println("  `make local-load` writes a local file instead — check --store and COSMOS_DB.")
		}
		return nil
	case err != nil:
		var schemaErr *pipeline.SchemaError
		if errors.As(err, &schemaErr) {
			// The pre-per-release format: a flat id list where the index should be.
			println("pool index: holds the pre-per-release format, which has no counts to report")
			println("  reload with this CLI to rewrite it; until then the web app reports no data.")
			return nil
		}
		return err
	}

	slugs := pipeline.Slugs(index)
	printf("knowledge graphs: %d\n", len(slugs))
	reserved := 1 // the index document itself
	for _, slug := range slugs {
		printf("  %s (%s%s)\n", slug, version.InforesPrefix, slug)
		for _, rel := range pipeline.Releases(index, slug) {
			printf("    %-12s %8d edges · %5d sampled%s\n",
				rel.Label, rel.Pool.Edges, rel.Pool.Sampled, sampledAt(rel.Pool.SampledAt))
			reserved++
			if f.checkPools {
				if err := reportPool(ctx, store, dict, slug, rel.Label, rel.Pool.Sampled); err != nil {
					return err
				}
			}
		}
	}
	if stats.Items >= 0 {
		edges := stats.Items - reserved
		printf("documents: %d = %d edges + %d pools + 1 index\n", stats.Items, edges, reserved-1)
		if edges < 0 {
			println("  (the count disagrees with the index: a load or a purge was interrupted)")
		}
	}
	printf("%.1f RU spent answering this\n", budget.Consumed())
	return nil
}

// reportPool point-reads one pool document and says what it costs. Size is the number that
// matters: Cosmos charges a point read per kilobyte of item, so the pool's stored bytes are
// directly the RU a random pick in that release spends. It reads the document once and decodes it
// here rather than calling the shared reader, because the shared reader would read it again.
func reportPool(ctx context.Context, store cosmos.Store, dict []byte, slug, label string, want int) error {
	id := cosmos.PoolDocID(slug, label)
	doc, err := store.Read(ctx, id)
	if err != nil {
		if errors.Is(err, cosmos.ErrNotFound) {
			printf("      pool document missing — the index lists a release with no pool\n")
			return nil
		}
		return fmt.Errorf("read pool %s: %w", id, err)
	}
	stored, err := pipeline.DictionaryFor(doc.DictID, dict)
	if err != nil {
		return fmt.Errorf("%s: %w", id, err)
	}
	var pool codec.Pool
	if err := codec.DecodeJSON(doc.Blob, stored, &pool); err != nil {
		return fmt.Errorf("decode %s: %w", id, err)
	}
	note := ""
	if len(pool.IDs) != want {
		note = fmt.Sprintf(", index says %d", want)
	}
	printf("      pool %s · %d ids%s · ~%.0f RU per random read\n",
		humanBytes(int64(len(doc.Blob))), len(pool.IDs), note, float64(len(doc.Blob))/1024)
	return nil
}

func sampledAt(at string) string {
	if at == "" {
		return ""
	}
	return " · " + at
}
