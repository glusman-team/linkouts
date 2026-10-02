# Storage format

The full contract is `docs/adr/0001-wire-format.md`. This page summarizes it.

## One document per edge

Cosmos holds one document per edge. Its `id` is the edge's KGX `id`:

```json
{"id": "12ae7437-12dc-3c2a-b487-5297c09fc5e5", "b": "<base64 zstd frame>", "d": 1162170161}
```

- `b` is a zstd frame holding a JSON blob with every stored version of the edge.
- `d` is the id of the dictionary the frame was compressed with. It is absent when no dictionary
  was used.

The container is partitioned and indexed on `/id` only. Every read is a point read, which is the
cheapest Cosmos operation. Indexing any other path would add write cost and buy nothing.

## Inside the frame

```json
{
  "schema": "edgelinkouts.blob/1",
  "versions": {
    "drug-approvals-kg-1.11.2": { "...the full edge document..." },
    "drug-approvals-kg-1.16.0": { "$t": "drug-approvals-kg-1.11.2", "$set": {"...": "..."}, "$del": ["..."] }
  }
}
```

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

## The random pool

The reserved document `__random_pool__` holds a reservoir sample of edge ids, which `/random` picks
from. Each `load` merges its sample into the existing pool rather than replacing it, so `/random`
covers every KG that has been loaded, not only the most recent one.
