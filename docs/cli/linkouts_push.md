## linkouts push

Mirror a staged file store into Cosmos, one create per document

### Synopsis

push streams every document from a local file store (--store file:PATH) into the
configured Cosmos container.

This is the cheap reload path: `load` merging into a live container pays a read plus a
conditional replace for every edge it merges, while pushing a locally staged store pays one
create per document. Stage with repeated `load --store file:...` runs (zero RU), then
push into a fresh container, point the app at it, and drop the old one - a blue/green cutover
with no downtime and the minimum write spend.

The write is a create; on a conflict the stored document is read and either skipped (identical
bytes, so a push is resumable) or replaced under its etag. Pool documents are pushed after every
edge, and the pool index last, so a reader that sees the index can resolve every pool it names.

--dry-run counts and sizes the staged documents without touching Cosmos, which is how a reload
estimates its RU cost before spending any.

```
linkouts push [flags]
```

### Options

```
      --concurrency int   concurrent document writes (default 8)
      --dry-run           report what would be pushed, touch nothing
  -h, --help              help for push
  -y, --yes               do not ask for confirmation
```

### Options inherited from parent commands

```
      --chdb-cache string   chdb extraction dir (default $CHDB_CACHE_DIR)
      --container string    Cosmos container (default $COSMOS_CONTAINER or edges)
      --db string           Cosmos database (default $COSMOS_DB or edge_linkouts)
      --engine string       join engine: chdb (embedded ClickHouse) or fake (pure Go) (default "chdb")
      --ru-budget float     RU/s ceiling (default $RU_BUDGET_CLI or 750)
      --store string        storage backend: cosmos, file:PATH, or mem:// (default "cosmos")
  -v, --verbose             log each step
```

### SEE ALSO

* [linkouts](linkouts.md)	 - Ingest Biolink KGX dumps into Cosmos DB and read them back

