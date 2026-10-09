## linkouts train-dict

Train a zstd dictionary from a KG's own documents

### Synopsis

train-dict runs the join over a sample of the input and builds the compression
dictionary that load and the web app both use.

Small JSON documents compress badly alone: most of an edge is key names that repeat on every
other edge. A dictionary trained on this KG's own shape is what takes a ~250-byte document to
~25 bytes, which is the difference between a point read costing 1 RU and costing 1 RU plus a
download the free tier has to serve thousands of times a day.

The dictionary is written to --out and committed to web/priv/zstd/ so the reader and the writer
always agree. The dictionary id is derived from the training samples, so retraining from the
same corpus keeps the id (a safe repack target) while a genuinely different corpus gets a new
one; a blob written with one dictionary can never be decoded with another.

```
linkouts train-dict [flags]
```

### Options

```
      --edges string   path to KGX edges.ndjson (required)
  -h, --help           help for train-dict
      --nodes string   path to KGX nodes.ndjson (required)
      --out string     dictionary output path (required)
      --samples int    documents to train from (default 4096)
      --threads int    ClickHouse max_threads (default: NumCPU)
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

