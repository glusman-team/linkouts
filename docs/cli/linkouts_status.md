## linkouts status

Report what the store holds and what it is configured to cost

### Synopsis

status answers "is my data actually in there, and what does it cost" without opening the
portal.

It reads the container's own metadata — document count, storage usage, partition key and indexing
policy — then point-reads the pool index to list every knowledge graph and release that has a
random pool, with the edge count and sample size each one carries. Both are cheap: a metadata read
and one small point read.

--check-pools additionally point-reads each pool document and reports its stored size, which is
what a random pick in that release costs in RU (Cosmos charges a point read by item size). That is
one read per release, so it is opt-in.

Indexing is expected to report "none". This app only ever point-reads by id, and an index would
add 10-20% to stored size plus write RU on every document for queries nobody issues; a portal
showing zero index storage is the configuration working, not data missing. What does mean data is
missing is a zero document count: loads run with --store file: never reach the cloud account.

```
linkouts status [flags]
```

### Options

```
      --check-pools   point-read every pool and report its stored size
      --dict string   trained zstd dictionary the blobs were written with
  -h, --help          help for status
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

