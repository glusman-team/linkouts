## linkouts probe

Measure the real cost of the web app's read path

### Synopsis

probe point-reads N edge documents and reports what they actually cost.

The number that matters is RU per read, because the free tier is 1000 RU/s shared with the CLI
and the web app is budgeted at 150. probe turns that budget from a guess into a measurement:
it reports mean and worst-case charge, the decoded document sizes, and how many reads per
second the budget allows.

IDs come from the per-release random pools a load writes, reached through the pool index, so
the sample spans every loaded release rather than being whatever happens to be first in the
file.

```
linkouts probe [flags]
```

### Options

```
      --dict string   trained zstd dictionary the blobs were written with
  -h, --help          help for probe
  -n, --n int         documents to read (default 20)
```

### Options inherited from parent commands

```
      --chdb-cache string   chdb extraction dir (default $CHDB_CACHE_DIR)
      --concurrency int     concurrent store operations (default 8)
      --container string    Cosmos container (default $COSMOS_CONTAINER or edges)
      --db string           Cosmos database (default $COSMOS_DB or edge_linkouts)
      --engine string       join engine: chdb (embedded ClickHouse) or fake (pure Go) (default "chdb")
      --ru-budget float     RU/s ceiling (default $RU_BUDGET_CLI or 750)
      --store string        storage backend: cosmos, file:PATH, or mem:// (default "cosmos")
  -v, --verbose             log each step
```

### SEE ALSO

* [linkouts](linkouts.md)	 - Ingest Biolink KGX dumps into Cosmos DB and read them back

