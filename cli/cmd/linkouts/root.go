package main

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/glusman-team/edge-linkouts/cli/internal/config"
	"github.com/glusman-team/edge-linkouts/cli/internal/cosmos"
	"github.com/glusman-team/edge-linkouts/cli/internal/engine"
	"github.com/glusman-team/edge-linkouts/cli/internal/ratelimit"
)

// version is stamped by the release build (-ldflags "-X main.version=...").
var buildVersion = "dev"

// globals holds the flags every subcommand shares.
type globals struct {
	storeSpec   string
	database    string
	container   string
	engineKind  string
	chdbCache   string
	ruBudget    float64
	concurrency int
	verbose     bool
}

func newRootCmd() *cobra.Command {
	g := &globals{}
	cmd := &cobra.Command{
		Use:   "linkouts",
		Short: "Ingest Biolink KGX dumps into Cosmos DB and read them back",
		Long: `linkouts turns KGX nodes.ndjson + edges.ndjson into one compressed, versioned
Cosmos DB document per edge UUID, and reads those documents back for inspection.

The web app is a separate program; this binary only writes and probes. Every command works
offline against a file store (--store file:PATH), which is how the tests and CI run.`,
		SilenceUsage:  true,
		SilenceErrors: true,
		Version:       buildVersion,
	}
	pf := cmd.PersistentFlags()
	pf.StringVar(&g.storeSpec, "store", envOr("LINKOUTS_STORE", "cosmos"),
		"storage backend: cosmos, file:PATH, or mem://")
	pf.StringVar(&g.database, "db", "", "Cosmos database (default $COSMOS_DB or "+config.DefaultDatabase+")")
	pf.StringVar(&g.container, "container", "", "Cosmos container (default $COSMOS_CONTAINER or "+config.DefaultContainer+")")
	pf.StringVar(&g.engineKind, "engine", envOr("LINKOUTS_ENGINE", "chdb"), "join engine: chdb (embedded ClickHouse) or fake (pure Go)")
	pf.StringVar(&g.chdbCache, "chdb-cache", "", "chdb extraction dir (default $CHDB_CACHE_DIR)")
	pf.Float64Var(&g.ruBudget, "ru-budget", 0, "RU/s ceiling (default $RU_BUDGET_CLI or 450)")
	pf.IntVar(&g.concurrency, "concurrency", 8, "concurrent store operations")
	pf.BoolVarP(&g.verbose, "verbose", "v", false, "log each step")

	cmd.AddCommand(newInitCmd(g), newLoadCmd(g), newGetCmd(g), newProbeCmd(g),
		newRigCmd(g), newTrainDictCmd(g), newDocsCmd())
	return cmd
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// resolve applies flag overrides to the environment-derived configuration.
func (g *globals) resolve() (config.Config, error) {
	cfg, err := config.Load(nil)
	if err != nil {
		return cfg, err
	}
	if g.database != "" {
		cfg.Cosmos.Database = g.database
	}
	if g.container != "" {
		cfg.Cosmos.Container = g.container
	}
	if g.ruBudget > 0 {
		cfg.RUps = g.ruBudget
	}
	if g.chdbCache != "" {
		cfg.ChdbCacheDir = g.chdbCache
	}
	return cfg, nil
}

// openStore builds the storage backend for a command.
func (g *globals) openStore(cfg config.Config, budget ratelimit.Budget) (cosmos.Store, error) {
	store, err := cosmos.Open(context.Background(), g.storeSpec, cfg.Cosmos, budget)
	if err != nil {
		return nil, err
	}
	g.logf("store: %s", store.Name())
	return store, nil
}

// openEngine builds the join backend. The embedded engine extracts ~540 MiB on first use, so
// the message says what is happening instead of appearing to hang.
func (g *globals) openEngine(cfg config.Config) (engine.Engine, error) {
	if g.engineKind != "fake" && g.verbose {
		fmt.Fprintln(os.Stderr, "starting embedded ClickHouse (first run extracts the engine, ~540 MiB)…")
	}
	e, err := engine.Open(g.engineKind, cfg.ChdbCacheDir, 0)
	if err != nil {
		return nil, err
	}
	g.logf("engine: %s", e.Name())
	return e, nil
}

func (g *globals) logf(format string, args ...any) {
	if g.verbose {
		fmt.Fprintf(os.Stderr, "linkouts: "+format+"\n", args...)
	}
}

// out is where command results go; a variable so tests can capture it.
var out io.Writer = os.Stdout

// printf writes a result line. The error is dropped on purpose: out is a terminal or a pipe,
// and a reader that went away must not turn a successful load into a reported failure. Every
// command prints through here so that decision is made once instead of at each call site.
func printf(format string, args ...any) { _, _ = fmt.Fprintf(out, format, args...) }

// println writes a result line with a newline.
func println(line string) { _, _ = fmt.Fprintln(out, line) }

// deferClose closes something whose Close can fail — the file store compacts and renames in
// Close, so swallowing that error could hide lost documents — without masking the error the
// command is already returning. Use with a named return: defer deferClose(store.Close, &err).
func deferClose(close func() error, err *error) {
	if cerr := close(); cerr != nil && *err == nil {
		*err = cerr
	}
}
