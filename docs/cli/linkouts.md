## linkouts

Ingest Biolink KGX dumps into Cosmos DB and read them back

### Synopsis

linkouts turns KGX nodes.ndjson + edges.ndjson into one compressed, versioned
Cosmos DB document per edge UUID, and reads those documents back for inspection.

The web app is a separate program; this binary only writes and probes. Every command works
offline against a file store (--store file:PATH), which is how the tests and CI run.

### Options

```
      --chdb-cache string   chdb extraction dir (default $CHDB_CACHE_DIR)
      --concurrency int     concurrent store operations (default 8)
      --container string    Cosmos container (default $COSMOS_CONTAINER or edges)
      --db string           Cosmos database (default $COSMOS_DB or edge_linkouts)
      --engine string       join engine: chdb (embedded ClickHouse) or fake (pure Go) (default "chdb")
  -h, --help                help for linkouts
      --ru-budget float     RU/s ceiling (default $RU_BUDGET_CLI or 450)
      --store string        storage backend: cosmos, file:PATH, or mem:// (default "cosmos")
  -v, --verbose             log each step
```

### SEE ALSO

* [linkouts docs](linkouts_docs.md)	 - Write the CLI reference as Markdown
* [linkouts get](linkouts_get.md)	 - Read one edge document and print a stored version
* [linkouts init](linkouts_init.md)	 - Create the Cosmos database and container if they are missing
* [linkouts load](linkouts_load.md)	 - Join KGX nodes and edges, then store one versioned blob per edge
* [linkouts probe](linkouts_probe.md)	 - Measure the real cost of the web app's read path
* [linkouts rig](linkouts_rig.md)	 - Inspect a KGX file and draft a display configuration for it
* [linkouts train-dict](linkouts_train-dict.md)	 - Train a zstd dictionary from a KG's own documents

