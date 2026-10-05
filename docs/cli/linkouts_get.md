## linkouts get

Read one edge document and print a stored version

### Synopsis

get point-reads one edge and expands the requested version.

This is the read path the web app uses, from the CLI: one point read, one zstd decode, then a
delta chain walk. Without --version the newest stored version is printed. --list shows every
version the document holds and how each is stored (full or delta, and against what).

```
linkouts get <edge-uuid> [flags]
```

### Options

```
      --dict string      trained zstd dictionary the blob was written with
  -h, --help             help for get
      --list             list stored versions instead of resolving one
      --raw              print the stored base64 frame
      --version string   version key to resolve (default: newest)
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

