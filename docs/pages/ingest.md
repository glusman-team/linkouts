# Ingesting a KG

## Inputs

A KGX release is two NDJSON files and a key:

- `nodes.ndjson`: one node per line, at least `id`, ideally `name` and `category`
- `edges.ndjson`: one edge per line. Every edge **must** carry an `id` field, and that id
  becomes the page URL. EdgeLinkouts never invents or hashes ids, so a KG without stable edge ids
  cannot have stable links.
- a version key `<name>-<version>`, for example `drug-approvals-kg-1.16.0`. The `<name>` part must
  match the `name:` of a display config in `kgs/`, or the page falls back to a generic view.

## One-time setup

```sh
cp .envrc.example .envrc   # fill in the read-write connection string
direnv allow
cli/bin/linkouts init      # creates the database and container if missing
```

`init` is idempotent. The container is partitioned and indexed on `/id` only: every read is a
point read by id, so indexing anything else would cost write RUs for nothing.

## Loading

```sh
cli/bin/linkouts load drug-approvals-kg-1.16.0 --nodes nodes.ndjson --edges edges.ndjson
```

What happens:

1. Embedded ClickHouse streams the edges and joins `subject_name`, `object_name` and their
   categories from the nodes. The join never materializes either file in Go memory.
2. Every null, empty string, empty list and `"None"`-like value is dropped, at any depth. A stored
   document never contains a null.
3. For each edge, the existing document is read. If it holds other versions, the new one is stored
   as a delta against the newest of them (or against `--base`), because consecutive releases
   differ in a few fields while distant ones differ everywhere. A version that other deltas
   depend on is always stored whole, so reloading an old release cannot create a cycle.
4. The document is written back with an ETag check, so two concurrent loads cannot silently lose
   each other's versions.
5. A reservoir sample of ids is written to the reserved `__random_pool__` document for `/random`.

Writes are paced to the RU budget (`--ru-budget`, default 450 RU/s) using the actual charge Cosmos
reports, so a load shares the free tier with the running web app instead of starving it.

## Useful flags

- `--dry-run`: run the whole pipeline, write nothing. Reports what would be created and merged.
- `--no-repack`: skip documents that already carry this key. Use it to resume an interrupted load.
- `--dict`: compress with a trained dictionary. See below.

## Dictionaries

Edge documents from one KG share most of their structure, so a zstd dictionary trained on them
compresses much better than zstd alone. On the drug approvals fixtures, stored size drops from
56% of raw to 46%.

```sh
cli/bin/linkouts train-dict drug-approvals-kg-1.16.0 --nodes nodes.ndjson --edges edges.ndjson --out edges.dict
cli/bin/linkouts load drug-approvals-kg-1.16.0 ... --dict edges.dict
```

The web app must be deployed with the same dictionary file, because each document records the id
of the dictionary it was written with. A mismatch fails with an error naming both ids, never with
garbage output.

## Measuring cost first

```sh
cli/bin/linkouts probe --n 20
```

`probe` reads 20 random documents the way the web app does and reports RU per read and latency.
Run it before sizing the RU budgets.
