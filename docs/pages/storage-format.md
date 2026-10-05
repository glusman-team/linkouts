# Storage format

The full contract is `docs/adr/0001-wire-format.md`. This page summarizes it.

## One document per edge

Cosmos holds one document per edge. Its `id` is the edge's KGX `id`:

```json
{"id": "12ae7437-12dc-3c2a-b487-5297c09fc5e5", "b": "<base64 zstd frame>", "d": 1162170161, "k": "drugapprovals-kp"}
```

- `b` is a zstd frame holding a JSON blob with every stored version of the edge.
- `d` is the id of the dictionary the frame was compressed with. It is absent when no dictionary
  was used.
- `k` is the slug of the knowledge graph the edge belongs to: its canonical name with the
  `infores:` prefix dropped. It is absent when empty, so documents written before it existed are
  unchanged. It sits outside the frame on purpose: "which graph is this?" should not cost a
  decompression, and the same slug names the graph in a URL and in a pool document id.

The container is partitioned on `/id` and its indexing policy is `none`: there is no indexed path
at all. Every read the app makes is a point read by id, which is the cheapest Cosmos operation,
and no query is ever issued, because without indexes a query would be a full scan at full price.
Indexing more paths would add write cost and buy nothing this app can use.

## Inside the frame

```json
{
  "schema": "edgelinkouts.blob/1",
  "versions": {
    "infores:drugapprovals-kp-1.11.2": { "...the full edge document..." },
    "infores:drugapprovals-kp-1.16.0": { "$t": "infores:drugapprovals-kp-1.11.2", "$set": {"...": "..."}, "$del": ["..."] }
  }
}
```

A version key is `<kg>-<version>`, and the `<kg>` is the infores the graph is registered under.

A version is stored one of two ways:

- **Full**: the complete edge document.
- **Delta**: `$t` names the version it applies to. `$del` removes keys, `$set` replaces values,
  and `$add` appends to lists. The three are applied in that order.

Consecutive releases usually differ in a few fields, so most versions after the first are a small
delta. A delta may target another delta. The reader follows the chain and rejects a cycle with an
error.

## Canonical JSON

Both writer and reader serialize documents the same way:

- keys sorted at every depth
- numbers kept as they appeared in the source (`1.0` stays `1.0`)
- only the escapes JSON requires, with no HTML escaping

A cross-language test decodes the Go writer's output in Elixir, re-encodes it, and requires the
same bytes. Because of this, a KGX download from the web app is byte-identical to what the CLI
stored.

## No nulls

No stored document contains `null`, at any depth. Before storing, the CLI drops every null-like
value: `null`, empty strings, empty lists and maps, lists whose elements are all null-like, and the
placeholder strings sources use for missing data (`None`, `null`, `NaN`, `NA`, `N/A`, `-`,
`unknown`, `not provided`). The comparison ignores case and surrounding whitespace.

So a missing value in the source becomes an absent field, never a placeholder. A config can test
for it with `{:present, field}`, and a number field never holds the string `"NA"`. The reader
rejects a full document that contains a null, because one would mean the writer has regressed.

## Random pools

`/random` needs an edge id without querying anything, so the ids are stored. Three reserved
documents do it, all point-readable by id:

- `__random_pool__` — the index: which graphs exist, which releases each has, and per release how
  many edges it holds and how many were sampled. Counts only, so it stays about a kilobyte
  however many graphs are loaded. The root page lists itself from this one document, and a
  whole-store random pick uses its counts to choose a release in proportion to its size, which
  is what keeps the pick uniform over edges rather than over releases.
- `__random_pool__:<slug>:<version>` — one release's reservoir sample of edge ids. `/<slug>/random`
  reads one of these; `/<slug>/random?version=<label>` reads exactly one and nothing else.

Each `load` writes its own release's pool and adds one entry to the index, so `/random` covers
every graph and release that has been loaded, not only the most recent one. Ids in a pool are
plain hex UUID strings: binary and delta-varint packings were measured and are larger once zstd
has done its work, and they would make the document unreadable in the portal. The sample cap
(`--sample-size`) is the lever that controls pool size.

`linkouts status` reads the same documents and reports what is stored, what the pools hold and
what the container's indexing policy is. `linkouts purge --key <slug>-<version>` drops one
release (its version entries, its pool, its index entry) and `purge --all` wipes the store.
