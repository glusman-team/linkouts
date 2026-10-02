## linkouts docs

Write the CLI reference as Markdown

### Synopsis

docs generates one Markdown page per command into --out, from the same flag
definitions the binary uses.

The generated tree is published to GitHub Pages beside the ExDoc output, so the CLI reference
cannot drift from the code: regenerating it is part of the docs build, and CI fails if the
committed copy is stale.

```
linkouts docs [flags]
```

### Options

```
  -h, --help         help for docs
      --out string   output directory (default "docs/cli")
```

### Options inherited from parent commands

```
      --chdb-cache string   chdb extraction dir (default $CHDB_CACHE_DIR)
      --concurrency int     concurrent store operations (default 8)
      --container string    Cosmos container (default $COSMOS_CONTAINER or edges)
      --db string           Cosmos database (default $COSMOS_DB or edge_linkouts)
      --engine string       join engine: chdb (embedded ClickHouse) or fake (pure Go) (default "chdb")
      --ru-budget float     RU/s ceiling (default $RU_BUDGET_CLI or 450)
      --store string        storage backend: cosmos, file:PATH, or mem:// (default "cosmos")
  -v, --verbose             log each step
```

### SEE ALSO

* [linkouts](linkouts.md)	 - Ingest Biolink KGX dumps into Cosmos DB and read them back

