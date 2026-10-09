## linkouts purge

Delete stored data: the whole store, one KG, or one release

### Synopsis

purge deletes stored documents. Nothing about it is recoverable.

--all wipes the container: on Cosmos it drops the container and provisions it again with the same
partition key and indexing policy, which is immediate and costs no RU. This is the path for a
schema change or a load that went wrong — wipe, then reload.

--kg <name> removes every release of one knowledge graph, and --key <kg-version> removes one
release. Both work by reading every document and dropping the matching version from each blob,
deleting the documents left with no versions at all, then removing the release's pool document and
its entry in the pool index. Names may be given with or without the infores: prefix.

Removing one release has to scan, and a scan needs an index: this container's indexing policy is
none, which is what keeps every read at 1 RU per KB and every write at its minimum. Cosmos will
therefore refuse it, and purge says so rather than pretending. The choices are --all (wipe and
reload) or switching the indexing policy to consistent first, which costs 10-20% extra storage and
index write RU on every document for as long as it stays on. File and memory stores can always
scan, so this works offline and in tests.

--dry-run reports what a targeted purge would do without touching the store.

```
linkouts purge [flags]
```

### Options

```
      --all              wipe every document, including the reserved pool documents
      --dict string      trained zstd dictionary the blobs were written with
      --drop-container   delete the container itself WITHOUT recreating it (blue/green cutover cleanup; Cosmos only)
      --dry-run          report what would be deleted, delete nothing
  -h, --help             help for purge
      --key string       one release to purge, as a <kg>-<version> key
      --kg string        KG to purge, by name or slug (every release of it)
  -y, --yes              do not ask for confirmation
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

