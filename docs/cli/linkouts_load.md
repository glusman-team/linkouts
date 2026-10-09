## linkouts load

Join KGX nodes and edges, then store one versioned blob per edge

### Synopsis

load reads a KGX release and writes one Cosmos DB document per edge UUID.

The key names the release being stored, as "<kg>-<version>" (infores:drugapprovals-kp-1.11.2).
It selects the display configuration the web app uses and is the version a later release diffs
against. The KG name is also stored on every document as its slug ("k": "drugapprovals-kp", the
name without the infores: prefix), and the release gets its own random pool document plus an
entry in the pool index, which is how /random can pick inside one KG or one release with point
reads alone.

Each edge is joined to its subject and object nodes to attach subject_name, subject_category,
object_name and object_category, then every nullish value is stripped. An unresolvable node
means the name field is absent, never null.

Writes are create-first: a fresh edge costs one request, and a 409 means the edge already has
versions, so the existing blob is read, this version is merged in as a delta when that is
smaller, and the document is replaced under an etag precondition.

```
linkouts load <kg-version-key> [flags]
```

### Options

```
      --base string       version key to diff against (default: newest stored)
      --dict string       trained zstd dictionary to compress with
      --dry-run           do everything except touch the store
      --edges string      path to KGX edges.ndjson (required)
  -h, --help              help for load
      --no-repack         skip documents that already carry this key
      --nodes string      path to KGX nodes.ndjson (required)
      --progress          print progress lines to stderr (default true)
      --sample-size int   ids to reservoir-sample for /random (0 disables) (default 1024)
      --threads int       ClickHouse max_threads (default: NumCPU)
      --zstd-level int    zstd compression level (default: 3 without a dictionary, 19 with one; dict frames are written once and read forever, so the high level is worth it)
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

