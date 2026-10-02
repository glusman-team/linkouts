## linkouts rig

Inspect a KGX file and draft a display configuration for it

### Synopsis

rig reads a KGX edges file and reports what is actually in it: which predicates
appear, which qualifier slots each one carries, how often, and with what value shapes.

That report is what a display configuration is written from. The legacy configs were
hand-maintained Perl that drifted from the data — fields renamed between releases, slots
dropped, new qualifiers nobody rendered. rig makes the drift visible, and --exs emits a
starter kgs/*.exs with every observed field wired to a template so nothing is silently
ignored.

Nothing is written to storage: rig only reads the file you point it at.

```
linkouts rig <edges.ndjson> [flags]
```

### Options

```
      --exs                emit a starter display config instead of a report
  -h, --help               help for rig
      --limit int          maximum edges to inspect (0 = all) (default 20000)
      --predicate string   restrict to one predicate
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

