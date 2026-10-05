# Ingesting a KG

## Inputs

A KGX release is two NDJSON files and a key:

- `nodes.ndjson`: one node per line, at least `id`, ideally `name` and `category`
- `edges.ndjson`: one edge per line. Every edge **must** carry an `id` field, and that id
  becomes the page URL. EdgeLinkouts never invents or hashes ids, so a KG without stable edge ids
  cannot have stable links.
- a version key `<name>-<version>`, for example `infores:drugapprovals-kp-1.16.0`. Use the
  canonical infores the graph is registered under: it is the identifier a curator can check and
  the one other Translator tools use. The name without its `infores:` prefix is the graph's
  **slug** (`drugapprovals-kp`), which is what the stored documents carry, what a URL carries
  (`/drugapprovals-kp/random`) and what a pool document id is built from. The `<name>` part must
  match the `name:` of a display config in `kgs/`, or the page falls back to a generic view.

## One-time setup

```sh
cp .envrc.example .envrc   # fill in the read-write connection string
direnv allow
cli/bin/linkouts init      # creates the database and container if missing
```

`init` is idempotent. The container is partitioned on `/id` and its indexing policy is `none`:
there is no indexed path, because every read the app makes is a point read by id. Indexing anything
would cost write RUs and storage for a query the app never issues.

## Loading

```sh
cli/bin/linkouts load infores:drugapprovals-kp-1.16.0 --nodes nodes.ndjson --edges edges.ndjson
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
5. A reservoir sample of this release's ids is written to its own reserved document,
   `__random_pool__:drugapprovals-kp:1.16.0`, and one entry is added to the reserved
   `__random_pool__` index. `/random` picks a release in proportion to its edge count and then
   picks inside that release's sample; `/<slug>/random?version=<label>` reads one pool and picks
   from it. Neither issues a query, which the container could not answer cheaply.

Writes are paced to the RU budget (`--ru-budget`, default 750 RU/s) using the actual charge Cosmos
reports, so a load shares the free tier with the running web app instead of starving it.

## Useful flags

- `--dry-run`: run the whole pipeline, write nothing. Reports what would be created and merged.
- `--no-repack`: skip documents that already carry this key. Use it to resume an interrupted load.
- `--sample-size`: how many ids a release's random pool holds (default 1024). This is the lever
  that controls pool storage: a pool is the only document that grows with the number of edges,
  and it stops growing at this cap.
- `--dict`: compress with a trained dictionary. See below.

## Dictionaries

Edge documents from one KG share most of their structure, so a zstd dictionary trained on them
compresses much better than zstd alone. On the drug approvals fixtures, stored size drops from
56% of raw to 46%.

```sh
cli/bin/linkouts train-dict infores:drugapprovals-kp-1.16.0 --nodes nodes.ndjson --edges edges.ndjson --out edges.dict
cli/bin/linkouts load infores:drugapprovals-kp-1.16.0 ... --dict edges.dict
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

## Checking what is stored

```sh
cli/bin/linkouts status                 # documents, graphs, releases, pool state, indexing policy
cli/bin/linkouts status --check-pools   # also read every pool and compare it with the index
```

`status` answers the questions the Azure portal does not: how many documents are stored, which
graphs and releases have a random pool, whether the container's indexing policy is what the app
assumes, and what the reads cost. With no pool index it says so plainly, which is what an
install loaded by an older CLI looks like.

## Removing data

```sh
cli/bin/linkouts purge --dry-run --key drugapprovals-kp-1.16.0
cli/bin/linkouts purge --key drugapprovals-kp-1.16.0 --yes
cli/bin/linkouts purge --all --yes
```

A `--key` purge removes one release: its version entry in every edge document that holds it, its
random pool, and its entry in the pool index. A document left with no versions is deleted rather
than stored empty. A version other deltas point at is materialised whole first, so removing one
release cannot break the chain the others resolve through.

`--all` drops every document, pools included, and asks for confirmation unless `--yes` is given.
It is also the migration off an older format: nothing reads a pre-per-release pool, so wiping and
reloading is the way to replace one.

A `--key` purge scans, because with no indexes there is nothing else to do; `--dry-run` reports
what it would remove and what it would cost before anything is written.
