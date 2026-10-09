package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/glusman-team/linkouts/cli/internal/cosmos"
	"github.com/glusman-team/linkouts/cli/internal/pipeline"
	"github.com/glusman-team/linkouts/cli/internal/ratelimit"
)

type pushFlags struct {
	concurrency int
	dryRun      bool
	yes         bool
}

func newPushCmd(g *globals) *cobra.Command {
	f := &pushFlags{}
	cmd := &cobra.Command{
		Use:   "push",
		Short: "Mirror a staged file store into Cosmos, one create per document",
		Long: `push streams every document from a local file store (--store file:PATH) into the
configured Cosmos container.

This is the cheap reload path: ` + "`load`" + ` merging into a live container pays a read plus a
conditional replace for every edge it merges, while pushing a locally staged store pays one
create per document. Stage with repeated ` + "`load --store file:...`" + ` runs (zero RU), then
push into a fresh container, point the app at it, and drop the old one - a blue/green cutover
with no downtime and the minimum write spend.

The write is a create; on a conflict the stored document is read and either skipped (identical
bytes, so a push is resumable) or replaced under its etag. Pool documents are pushed after every
edge, and the pool index last, so a reader that sees the index can resolve every pool it names.

--dry-run counts and sizes the staged documents without touching Cosmos, which is how a reload
estimates its RU cost before spending any.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runPush(cmd.Context(), g, f)
		},
	}
	cmd.Flags().IntVar(&f.concurrency, "concurrency", 8, "concurrent document writes")
	cmd.Flags().BoolVar(&f.dryRun, "dry-run", false, "report what would be pushed, touch nothing")
	cmd.Flags().BoolVarP(&f.yes, "yes", "y", false, "do not ask for confirmation")
	return cmd
}

func runPush(ctx context.Context, g *globals, f *pushFlags) (err error) {
	if !strings.HasPrefix(g.storeSpec, "file:") && !strings.HasPrefix(g.storeSpec, "mem://") {
		return fmt.Errorf("push reads a staged local store: pass --store file:PATH (got %q)", g.storeSpec)
	}

	cfg, err := g.resolve()
	if err != nil {
		return err
	}
	// The source is local and free; only the target spends RU.
	source, err := g.openStore(cfg, ratelimit.NewUnlimited())
	if err != nil {
		return err
	}
	defer deferClose(source.Close, &err)

	if f.dryRun {
		return pushDryRun(ctx, source)
	}

	budget := ratelimit.New(cfg.RUps)
	target, err := cosmos.Open(ctx, "cosmos", cfg.Cosmos, budget)
	if err != nil {
		return err
	}
	defer deferClose(target.Close, &err)

	if !f.yes {
		stats, serr := source.Stats(ctx)
		count := "unknown number of"
		if serr == nil && stats.Items >= 0 {
			count = fmt.Sprintf("%d", stats.Items)
		}
		ok, cerr := confirmPrompt(fmt.Sprintf("push %s documents from %s into %s/%s?",
			count, source.Name(), cfg.Cosmos.Database, cfg.Cosmos.Container), f.yes)
		if cerr != nil {
			return cerr
		}
		if !ok {
			return errors.New("aborted")
		}
	}

	stats, err := pipeline.Push(ctx, pipeline.PushOptions{
		Source:      source,
		Target:      target,
		Budget:      budget,
		Concurrency: f.concurrency,
	})
	printf("pushed %d of %d: %d created, %d skipped (identical), %d replaced, %d failed; %.0f RU spent\n",
		stats.Created+stats.Skipped+stats.Replaced, stats.Read,
		stats.Created, stats.Skipped, stats.Replaced, stats.Failed, budget.Consumed())
	if err != nil {
		return err
	}
	if stats.Failed > 0 {
		return fmt.Errorf("%d documents failed; rerun to resume", stats.Failed)
	}
	return nil
}

// pushDryRun walks the source and reports document counts and sizes, so the reload runbook can
// estimate RU (one create per document, charged by size) before spending anything.
func pushDryRun(ctx context.Context, source cosmos.Store) error {
	var docs, reserved, over1KB int
	var totalBytes int64
	err := source.All(ctx, func(d cosmos.Doc) error {
		docs++
		if cosmos.IsReservedID(d.ID) {
			reserved++
		}
		if n := len(d.Blob); n > 1024 {
			over1KB++
		}
		totalBytes += int64(len(d.Blob))
		return nil
	})
	if err != nil {
		return err
	}
	printf("dry run: %d documents (%d reserved), %d over 1 KB payload, %d blob bytes total\n",
		docs, reserved, over1KB, totalBytes)
	return nil
}

// confirmPrompt asks on a terminal before a push writes to Cosmos; --yes skips it, and a
// non-terminal stdin refuses (so a piped invocation can never write by accident).
func confirmPrompt(prompt string, assumeYes bool) (bool, error) {
	if assumeYes {
		return true, nil
	}
	info, err := os.Stdin.Stat()
	if err != nil {
		return false, fmt.Errorf("cannot tell whether stdin is a terminal: %w (pass --yes)", err)
	}
	if info.Mode()&os.ModeCharDevice == 0 {
		return false, errors.New("refusing to write without a confirmation: pass --yes")
	}
	fmt.Fprintf(os.Stderr, "%s [y/N] ", prompt)
	answer, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil {
		return false, fmt.Errorf("read confirmation: %w", err)
	}
	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true, nil
	default:
		return false, nil
	}
}
