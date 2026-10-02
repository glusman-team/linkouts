package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/glusman-team/edge-linkouts/cli/internal/codec"
	"github.com/glusman-team/edge-linkouts/cli/internal/pipeline"
	"github.com/glusman-team/edge-linkouts/cli/internal/ratelimit"
	"github.com/glusman-team/edge-linkouts/cli/internal/version"
)

type loadFlags struct {
	nodes      string
	edges      string
	base       string
	dict       string
	zstdLevel  int
	noRepack   bool
	dryRun     bool
	sampleSize int
	sampleSeed int64
	sampledAt  string
	threads    int
	progress   bool
}

func newLoadCmd(g *globals) *cobra.Command {
	f := &loadFlags{}
	cmd := &cobra.Command{
		Use:   "load <kg-version-key>",
		Short: "Join KGX nodes and edges, then store one versioned blob per edge",
		Long: `load reads a KGX release and writes one Cosmos DB document per edge UUID.

The key names the release being stored, as "<kg>-<version>" (drug-approvals-kg-1.11.2). It
selects the display configuration the web app uses and is the version a later release diffs
against. The key is opaque to storage: nothing per-KG is stored on the edge itself.

Each edge is joined to its subject and object nodes to attach subject_name, subject_category,
object_name and object_category, then every nullish value is stripped. An unresolvable node
means the name field is absent, never null.

Writes are create-first: a fresh edge costs one request, and a 409 means the edge already has
versions, so the existing blob is read, this version is merged in as a delta when that is
smaller, and the document is replaced under an etag precondition.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := runLoad(cmd.Context(), g, args[0], f); err != nil {
				return err
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&f.nodes, "nodes", "", "path to KGX nodes.ndjson (required)")
	cmd.Flags().StringVar(&f.edges, "edges", "", "path to KGX edges.ndjson (required)")
	cmd.Flags().StringVar(&f.base, "base", "", "version key to diff against (default: newest stored)")
	cmd.Flags().StringVar(&f.dict, "dict", "", "trained zstd dictionary to compress with")
	cmd.Flags().IntVar(&f.zstdLevel, "zstd-level", codec.DefaultZstdLevel, "zstd compression level")
	cmd.Flags().BoolVar(&f.noRepack, "no-repack", false, "skip documents that already carry this key")
	cmd.Flags().BoolVar(&f.dryRun, "dry-run", false, "do everything except touch the store")
	cmd.Flags().IntVar(&f.sampleSize, "sample-size", pipeline.DefaultSampleSize, "ids to reservoir-sample for /random (0 disables)")
	cmd.Flags().IntVar(&f.threads, "threads", 0, "ClickHouse max_threads (default: NumCPU)")
	cmd.Flags().BoolVar(&f.progress, "progress", true, "print progress lines to stderr")
	// Hidden: only `make contract` uses these, so the committed fixtures regenerate to the same
	// bytes. They are not part of the user-facing CLI and are left out of its generated reference.
	cmd.Flags().Int64Var(&f.sampleSeed, "sample-seed", 0, "fix the /random reservoir seed (fixtures only)")
	cmd.Flags().StringVar(&f.sampledAt, "sampled-at", "", "fix the pool timestamp, RFC 3339 (fixtures only)")
	_ = cmd.Flags().MarkHidden("sample-seed")
	_ = cmd.Flags().MarkHidden("sampled-at")
	_ = cmd.MarkFlagRequired("nodes")
	_ = cmd.MarkFlagRequired("edges")
	return cmd
}

func runLoad(ctx context.Context, g *globals, key string, f *loadFlags) (err error) {
	cfg, err := g.resolve()
	if err != nil {
		return err
	}
	parsed, err := version.Parse(key)
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
	eng, err := g.openEngine(cfg)
	if err != nil {
		return err
	}
	defer deferClose(eng.Close, &err)

	var now func() time.Time
	if f.sampledAt != "" {
		at, err := time.Parse(time.RFC3339, f.sampledAt)
		if err != nil {
			return fmt.Errorf("--sampled-at: %w", err)
		}
		now = func() time.Time { return at }
	}
	opt := pipeline.Options{
		Now:         now,
		Key:         key,
		BaseKey:     f.base,
		NodesPath:   f.nodes,
		EdgesPath:   f.edges,
		Store:       store,
		Engine:      eng,
		Budget:      budget,
		Dict:        dict,
		ZstdLevel:   f.zstdLevel,
		DryRun:      f.dryRun,
		NoRepack:    f.noRepack,
		Concurrency: g.concurrency,
		SampleSize:  f.sampleSize,
		SampleSeed:  f.sampleSeed,
		Threads:     f.threads,
	}
	if f.progress {
		opt.Progress = pipeline.NewTextProgress(os.Stderr, 0)
	}

	g.logf("loading %s (kg=%s version=%s)", key, parsed.KG, parsed.Version())
	stats, err := pipeline.Load(ctx, opt)
	if stats != nil {
		printStats(stats, budget, dict)
	}
	if err != nil {
		return err
	}
	if stats.Failed > 0 {
		return fmt.Errorf("%d edges failed to store", stats.Failed)
	}
	return nil
}

func printStats(s *pipeline.Stats, budget ratelimit.Budget, dict []byte) {
	snap := s.Snapshot()
	printf("%s: %d edges in %s (%.0f/s)\n", snap.Key, snap.Edges, snap.Elapsed.Round(time.Millisecond), snap.Rate())
	printf("  created %d · merged %d · skipped %d · failed %d · versions %d\n",
		snap.Created, snap.Merged, snap.Skipped, snap.Failed, snap.Versions)
	printf("  %s raw → %s stored (ratio %.3f, dictionary %s)\n",
		humanBytes(snap.RawBytes), humanBytes(snap.BlobBytes), snap.Ratio(), dictLabel(dict))
	printf("  %.1f RU spent (%.1f RU/s ceiling, %d paced waits)\n",
		budget.Consumed(), budget.Rate(), snap.Waits)
	if snap.Sampled > 0 {
		printf("  /random pool: %d ids sampled from %d\n", snap.Sampled, snap.Offered)
	}
}

func dictLabel(dict []byte) string {
	if len(dict) == 0 {
		return "none"
	}
	return fmt.Sprintf("%#x, %s", codec.DictID(dict), humanBytes(int64(len(dict))))
}

func readDict(path string) ([]byte, error) {
	if path == "" {
		return nil, nil
	}
	dict, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read dictionary %s: %w", path, err)
	}
	if len(dict) == 0 {
		return nil, fmt.Errorf("dictionary %s is empty", path)
	}
	return dict, nil
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}
