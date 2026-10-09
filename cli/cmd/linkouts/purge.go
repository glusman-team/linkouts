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
	"github.com/glusman-team/linkouts/cli/internal/version"
)

type purgeFlags struct {
	all           bool
	dropContainer bool
	kg            string
	key           string
	dict          string
	yes           bool
	dryRun        bool
}

func newPurgeCmd(g *globals) *cobra.Command {
	f := &purgeFlags{}
	cmd := &cobra.Command{
		Use:   "purge",
		Short: "Delete stored data: the whole store, one KG, or one release",
		Long: `purge deletes stored documents. Nothing about it is recoverable.

--all wipes the container: on Cosmos it drops the container and provisions it again with the same
partition key and indexing policy, which is immediate and costs no RU. This is the path for a
schema change or a load that went wrong — wipe, then reload.

--kg <name> removes every release of one knowledge graph, and --key <kg-version> removes one
release. Both work by reading every document and dropping the matching version from each blob,
deleting the documents left with no versions at all, then removing the release's pool document and
its entry in the pool index. Names may be given with or without the infores: prefix.

Removing one release has to scan, and a scan needs an index: this container's indexing policy is
none, which is what keeps every read at 1 RU per KB and every write at its minimum. Cosmos will
therefore refuse it, and purge says so rather than pretending. The choices are --all (wipe and
reload) or switching the indexing policy to consistent first, which costs 10-20% extra storage and
index write RU on every document for as long as it stays on. File and memory stores can always
scan, so this works offline and in tests.

--dry-run reports what a targeted purge would do without touching the store.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runPurge(cmd.Context(), g, f)
		},
	}
	cmd.Flags().BoolVar(&f.all, "all", false, "wipe every document, including the reserved pool documents")
	cmd.Flags().BoolVar(&f.dropContainer, "drop-container", false,
		"delete the container itself WITHOUT recreating it (blue/green cutover cleanup; Cosmos only)")

	cmd.Flags().StringVar(&f.kg, "kg", "", "KG to purge, by name or slug (every release of it)")
	cmd.Flags().StringVar(&f.key, "key", "", "one release to purge, as a <kg>-<version> key")
	cmd.Flags().StringVar(&f.dict, "dict", "", "trained zstd dictionary the blobs were written with")
	cmd.Flags().BoolVar(&f.dryRun, "dry-run", false, "report what would be deleted, delete nothing")
	cmd.Flags().BoolVarP(&f.yes, "yes", "y", false, "do not ask for confirmation")
	return cmd
}

func runPurge(ctx context.Context, g *globals, f *purgeFlags) (err error) {
	selected := 0
	for _, on := range []bool{f.all, f.dropContainer, f.kg != "", f.key != ""} {
		if on {
			selected++
		}
	}
	if selected == 0 {
		return errors.New("purge needs one of --all, --drop-container, --kg <name>, --key <kg-version>")
	}
	if selected > 1 {
		return errors.New("purge takes exactly one of --all, --drop-container, --kg, --key")
	}
	// Checked before any config is resolved or store opened: --dry-run promises "delete
	// nothing", and dropping a container has no meaningful dry run to report.
	if f.dropContainer && f.dryRun {
		return errors.New("--dry-run cannot be combined with --drop-container; dropping a container has nothing to preview")
	}

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

	if f.dropContainer {
		return dropContainer(ctx, store, f.yes)
	}

	opt := pipeline.PurgeOptions{
		Store:     store,
		Dict:      dict,
		Budget:    budget,
		All:       f.all,
		DryRun:    f.dryRun,
		ZstdLevel: 0, // the codec's default; purge rewrites with the same settings it read with
	}
	switch {
	case f.key != "":
		parsed, err := version.Parse(f.key)
		if err != nil {
			return err
		}
		opt.Slug, opt.VersionLabel = parsed.Slug(), parsed.Version()
	case f.kg != "":
		opt.Slug = version.Slug(strings.TrimSpace(f.kg))
	}

	if ok, err := confirmPurge(store.Name(), opt, f.yes); err != nil {
		return err
	} else if !ok {
		println("cancelled")
		return nil
	}

	printf("purging %s from %s%s\n", purgeTargetLabel(opt), store.Name(), dryRunLabel(f.dryRun))
	if !f.dryRun {
		opt.OnScan = func(scanned, matched int64) {
			printf("  scanned %d documents, %d matched…\n", scanned, matched)
		}
	}
	stats, err := pipeline.Purge(ctx, opt)
	if stats != nil {
		printPurgeStats(stats, budget)
	}
	if err != nil {
		if errors.Is(err, cosmos.ErrScanUnsupported) {
			// The pipeline already explains the indexing policy; this adds the way out.
			return fmt.Errorf("%w\n  (a whole-store wipe does not need a scan: `linkouts purge --all`, then reload)", err)
		}
		return err
	}
	return nil
}

func purgeTargetLabel(o pipeline.PurgeOptions) string {
	switch {
	case o.All:
		return "everything"
	case o.VersionLabel != "":
		return fmt.Sprintf("%s %s", o.Slug, o.VersionLabel)
	default:
		return fmt.Sprintf("every release of %s", o.Slug)
	}
}

func dryRunLabel(dry bool) string {
	if dry {
		return " (dry run)"
	}
	return ""
}

func printPurgeStats(s *pipeline.PurgeStats, budget ratelimit.Budget) {
	if s.Dropped {
		println("  store wiped: every document is gone")
	} else {
		printf("  scanned %d documents\n", s.Scanned)
		printf("  removed %d versions · deleted %d documents · rewrote %d\n",
			s.Versions, s.Deleted, s.Rewritten)
	}
	if s.Pools > 0 || s.IndexEntries > 0 {
		printf("  deleted %d pool documents · removed %d index entries\n", s.Pools, s.IndexEntries)
	}
	printf("  %.1f RU spent (%.1f RU/s ceiling)\n", budget.Consumed(), budget.Rate())
}

// confirmPurge asks before deleting, because there is no undo. It does not prompt when stdin is
// not a terminal: a prompt nobody can answer would hang a scripted run, so a script that wants a
// deletion has to say --yes.
func confirmPurge(storeName string, o pipeline.PurgeOptions, assumeYes bool) (bool, error) {
	if assumeYes || o.DryRun {
		return true, nil
	}
	info, err := os.Stdin.Stat()
	if err != nil {
		return false, fmt.Errorf("cannot tell whether stdin is a terminal: %w (pass --yes)", err)
	}
	if info.Mode()&os.ModeCharDevice == 0 {
		return false, errors.New("refusing to delete without a confirmation: pass --yes")
	}
	prompt := fmt.Sprintf("delete %s from %s?", purgeTargetLabel(o), storeName)
	if o.All {
		prompt = fmt.Sprintf("delete EVERY document in %s? This cannot be undone.", storeName)
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

// containerDropper is implemented by the Azure backend; file and memory stores have no
// container to drop.
type containerDropper interface {
	DropOnly(ctx context.Context) error
}

// dropContainer deletes the container without recreating it - the cleanup half of a
// blue/green cutover (`push` into the new container, flip the app, drop the old one).
// Deleting a container is control plane work and costs no RU, unlike a document purge.
func dropContainer(ctx context.Context, store cosmos.Store, assumeYes bool) error {
	d, ok := store.(containerDropper)
	if !ok {
		return fmt.Errorf("--drop-container only works against Cosmos (this is %s)", store.Name())
	}
	ok, err := confirmPrompt(fmt.Sprintf("delete the WHOLE container behind %s? This cannot be undone.",
		store.Name()), assumeYes)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("aborted")
	}
	if err := d.DropOnly(ctx); err != nil {
		return err
	}
	printf("container dropped: %s\n", store.Name())
	return nil
}
