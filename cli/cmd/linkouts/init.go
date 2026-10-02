package main

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/glusman-team/edge-linkouts/cli/internal/config"
	"github.com/glusman-team/edge-linkouts/cli/internal/ratelimit"
)

func newInitCmd(g *globals) *cobra.Command {
	return &cobra.Command{
		Use:   "init",
		Short: "Create the Cosmos database and container if they are missing",
		Long: `init provisions the storage this project uses and is safe to re-run.

The container is created with partition key /id, indexing mode none and every path excluded,
because the only access pattern is a point read by edge UUID and every indexed path is RU
charged on every write. Throughput is manual at 1000 RU/s, the free-tier ceiling.

An existing database or container is left alone: a 409 is treated as success, so running init
against an account that already has them changes nothing.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) (err error) {
			cfg, err := g.resolve()
			if err != nil {
				return err
			}
			if !cfg.Cosmos.Ready() {
				return fmt.Errorf("no Cosmos account configured: set COSMOS_PRIMARY_CONNECTION_STRING_RW (see .envrc.example), or use --store file:PATH")
			}
			store, err := g.openStore(cfg, ratelimit.NewUnlimited())
			if err != nil {
				return err
			}
			defer deferClose(store.Close, &err)
			printf("provisioning %s/%s on %s\n", cfg.Cosmos.Database, cfg.Cosmos.Container, cfg.Cosmos.Endpoint)
			printf("  partition key %s · indexing none · manual %d RU/s · key %s\n",
				config.PartitionKeyPath, cfg.Cosmos.Throughput, config.MaskKey(cfg.Cosmos.Key))
			if err := store.Provision(cmd.Context()); err != nil {
				return err
			}
			println("ready")
			return nil
		},
	}
}
