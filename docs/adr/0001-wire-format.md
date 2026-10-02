# 1. Blob wire format (Go writer, Elixir reader)

Status: accepted. Implemented in `cli/internal/codec`; checked against the Elixir reader by
`web/test/contract_test.exs` and the golden files in `cli/testdata/contract/`.

This is the only interface between the two languages. Both sides must agree **byte for
byte**, because the CLI hashes canonical bytes to decide whether a version changed and the
web app re-encodes for KGX download.

## Cosmos document

```json
{ "id": "575af3e8-8015-3718-be03-4da18a0bacfc", "b": "KLUv/QAMAdw…", "d": 1163284273 }
```

- `id` — the edge UUID, taken verbatim from the KGX `id` field. It is also the partition
  key (`/id`) and the only indexed path, so this document is reachable by exactly one point
  read and nothing else is queryable.
- `b` — base64 (standard alphabet, padded) of one zstd frame holding the blob JSON below.
- `d` — dictionary id the frame was compressed with; **omitted when 0** (no dictionary).
  Present so a reader holding the wrong dictionary fails loudly instead of returning
  garbage. Dictionaries are trained by the CLI and committed at `web/priv/zstd/edges.dict`.

Deviation from PLAN.md's `{id, b}` sketch: the `d` field is added. A blob compressed
against a trained dictionary cannot be decoded without it, and there is no other place to
record which dictionary was in force when the document was written.

One reserved document id, `__random_pool__`, holds the reservoir-sampled UUID list that
backs `/random` (indexing is off, so a random-document query would be a cross-partition
scan). It uses the same envelope with `b` holding `{"schema":"edgelinkouts.pool/1", ...}`.

## Blob JSON (inside the frame)

```json
{
  "schema": "edgelinkouts.blob/1",
  "versions": {
    "drug-approvals-kg-1.11.2": { "id": "…", "subject": "CHEBI:64019", "predicate": "biolink:treats" },
    "drug-approvals-kg-1.12.0": {
      "$t": "drug-approvals-kg-1.11.2",
      "$set": { "clinical_approval_status": "approved_for_condition" },
      "$add": { "publications": ["PMID:40123456"] },
      "$del": ["number_of_cases"]
    }
  }
}
```

Deviation from PLAN.md: the version map is wrapped in an envelope carrying `schema`, so a
reader can refuse a format it does not implement rather than mis-decoding one. A reader
must reject any `schema` it does not know exactly.

Version keys are `<kg>-<version>` (`multiomics-kg-1.12.0`), opaque strings. Ordering for the
UI is the KG's own release order, not lexicographic.

### Two payload shapes

A version payload is either

1. **full** — a JSON object with no `$`-prefixed keys: the complete edge document; or
2. **delta** — an object with `$t` naming the version it applies to, plus any of:
   - `$set`: object of keys whose value changed or is new here
   - `$add`: object mapping a field to the list elements **appended** to that field's list
   - `$del`: array of key names present in the base and absent here

Resolution: `resolve(v)` = the payload if full, else `apply(resolve($t), payload)`.
Application order is `$del`, then `$set`, then `$add`. A cycle is an error, not a loop.

`$add` exists for KGX `publications` lists, which grow between releases: one edge in the
DAKP fixtures carries 3158 PMIDs, so appending one element instead of re-storing the list
is the single largest saving in this workload. `$add` is only emitted when the base list is
a strict prefix of the new one — reordering or shrinking falls back to `$set`.

An **empty but present** `$set` (`{"$t":"v1","$set":{}}`) means "identical to the base" and
is the cheapest legal payload. A delta with none of the three keys is corrupt and must be
rejected. `null` vs `{}` therefore carries meaning; a reader must not normalize one into
the other.

Whether a version is stored full or as a delta is decided by comparing canonical byte sizes
of both candidates and keeping the smaller — not by counting changed keys.

## Canonical JSON

The bytes inside the frame are canonical, and canonical means:

1. Object keys sorted by byte order (UTF-8 code unit order) at **every** depth.
2. No insignificant whitespace; separators are `,` and `:`.
3. **No nulls anywhere.** A null at any depth is a contract violation and must be rejected
   on read as well as never written. Absence is expressed by omitting the key (`$del` for a
   removal). Nullish values — `null`, `""`, `"None"`, `"NULL"`, `"nan"`, `"N/A"`, `"-"`,
   `"unknown"`, `"not provided"`, empty arrays, empty objects — are stripped by the join
   before encoding.
4. Numbers keep their input text. `15.0` stays `15.0`, `9007199254740993` stays exact (no
   float64 round trip). Integers are never quoted.
5. `<`, `>`, `&` are **not** escaped. Go's `encoding/json` escapes them by default
   (`\u003c`); Elixir's `JSON` does not. HTML escaping must be off on the Go side
   (`sonic.Config{EscapeHTML: false}`) or the two languages disagree on bytes.
6. Strings are UTF-8, with the JSON-mandatory escapes only (`"`, `\`, and U+0000–U+001F).

Go implementation: `sonic.Config{SortMapKeys: true, UseNumber: true, CopyString: true,
EscapeHTML: false}.Froze()`. Elixir implementation must sort keys explicitly — do not rely
on map iteration order.

Note that ClickHouse's `toJSONString` also sorts keys and drops null paths, but it
re-serializes numbers to shortest form (`15.0` → `15`) and its 64-bit integer quoting is
engine-specific. The engine output is therefore always re-parsed and re-encoded by
`codec.Marshal` before it reaches a blob, so the wire format does not depend on the engine
version.

## Compression

- Algorithm: zstd, one frame per document, level 3 by default (`--zstd-level`).
- Dictionary: trained from the KG's own documents via `zstd.BuildDict`, id
  `0x454C4F31` ("ELO1"). Small JSON documents are mostly repeated key names, so a trained
  dictionary is what takes a ~250-byte document to ~25 bytes (measured).
- Training detail that bites: `BuildDict` needs `History` **and** `Contents`. If the history
  buffer covers the samples, every sample compresses to pure matches and the builder aborts
  with `0 literals found`. History is therefore capped at 1/8 of total sample bytes
  (and at 128 KiB).
- Base64 uses the standard alphabet with padding, so the stored string is safe in JSON and
  in a URL.

## What the reader must tolerate

- A version key it has no display configuration for: render raw KGX, do not 500.
- Fields renamed between KG releases (measured in DAKP: `FDA_regulatory_approvals` →
  `regulatory_approvals`), which is why display configs carry version-scoped aliases.
- `d` absent (no dictionary) as well as present.
- A blob whose `schema` it does not know: refuse with a clear error.
