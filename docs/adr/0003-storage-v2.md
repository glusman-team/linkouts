# 3. Storage v2: trained zstd dictionary, staged file-store reload

Status: accepted. Replaces the per-document plain-zstd blobs of v1.

## Context

Every page view is one Cosmos point read, and a read of a document up to 1 KB costs 1 RU;
above that it bills per additional KB. The live corpus (DRUG_APPROVALS_KP 1.23.3 + 1.23.4,
138k edges each) compressed plain at level 3 stored 127.3 MiB from 189.5 MiB of JSON
(ratio 0.672), with a median edge document around 700-800 bytes and a long tail over 1 KB
that billed 2+ RU per view. Edge documents are highly redundant across the corpus (same
property names, same node categories, same evidence shapes), which is exactly what a
trained dictionary exploits.

## Decision

- Compress every blob against a trained zstd dictionary at level 19, using
  `klauspost/compress`'s `EncodeAll`/`DecodeAll` with pooled, CRC-less frames.
- Train one dictionary per KG with `linkouts train-dict` (8000 samples from the newest
  release, ~13 s). The production dictionary for `drugapprovals-kp` is
  `web/priv/zstd/drugapprovals-kp.77140996.dict` (128 KiB).
- Dictionary id = FNV-1a 32 over the training samples, mapped into the legal zstd
  content-id range, so the id is content-derived and cannot silently collide across KGs
  (v1's fixed id could). The id is written both in the zstd frame header and in the
  document's `d` field (ADR 0001).
- The web app resolves ids through `EdgeLinkouts.Dicts`, a registry loaded from
  `priv/zstd/` at boot (`reload!/0`, loud raise on a non-dict file or duplicate id). An
  unknown `d` decodes to `{:error, reason}` with a human-readable message; it never
  crashes the request.
- Reload path is stage-then-mirror: `linkouts load --store file:PATH` writes the whole
  release into a local file store at zero RU, then `linkouts push` mirrors it into the
  Cosmos container with one create per document (skipping identical, replacing changed),
  instead of v1's read-merge-write per document. `linkouts purge --drop-container`
  removes a container entirely for clean format swaps.
- `--zstd-level` default 0 means "3 without a dictionary, 19 with one".

## Measured effect (same corpus, same CLI)

| format | raw | stored | ratio |
|---|---|---|---|
| v1 plain level 3 | 189.5 MiB | 127.3 MiB | 0.672 |
| v2 dict level 19 | 189.5 MiB | ~68 MiB | 0.358 |

Median edge document 474 bytes; 91.1% of documents are at or below 834 bytes, so nearly
every view is one 1-RU read. The dictionary is 128 KiB, held in memory once per node, not
stored per document.

## Rejected alternatives

- base85 or any text-safe envelope: +25% bytes for no benefit; the blob is binary and
  stored in a binary field.
- Storing the dictionary inline per document: 128 KiB per document would dominate the
  payload it exists to shrink.
- Level 22: measurably slower to encode with negligible size gain over 19 on this corpus.
- Per-KG-version dictionaries (one per release): more registry entries, more training
  runs, and cross-release decode ambiguity; one dictionary per KG is enough because the
  redundancy is structural, not release-specific.
- Live in-place upgrade of v1 documents: would need a read-merge-write per document
  (2+ RU each, ~1.5M RU per release) with mixed formats visible to readers mid-migration.
  Staging to a NEW container (`edges_v2`) and flipping `COSMOS_CONTAINER` atomically keeps
  the old data serving until the swap, and `purge --drop-container` removes it afterwards.

## Contract

`cli/testdata/contract/` and `web/test/fixtures/contract/` hold byte-identical golden
documents (including `dictdocs.ndjson` + `dictdocs.golden.ndjson` for the dictionary path);
`make contract-check` fails if the Go writer and the Elixir reader ever disagree, and the
fixtures are committed so CI can run offline.
