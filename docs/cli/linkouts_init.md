## linkouts init

Create the Cosmos database and container if they are missing

### Synopsis

init provisions the storage this project uses and is safe to re-run.

The container is created with partition key /id, indexing mode none and every path excluded,
because the only access pattern is a point read by edge UUID and every indexed path is RU
charged on every write. Throughput is manual at 1000 RU/s, the free-tier ceiling.

An existing database or container is left alone: a 409 is treated as success, so running init
against an account that already has them changes nothing.

```
linkouts init [flags]
```

### Options

```
  -h, --help   help for init
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

