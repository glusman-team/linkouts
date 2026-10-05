# KG quick bar on `/`, per-KG and per-version `random`, KG name on docs, `linkouts purge`

## Context

`PLAN.md [D6]` dropped "KG-scoped random edge" in the first build; this change brings it
back — plus a KG overview bar at the root and per-version random. User decisions locked:

1. **KG identifier = the infores name.** Canonical name becomes `infores:drugapprovals-kp`
   (replaces `drug-approvals-kg`) in the display config `name` and the load keys
   (`infores:drugapprovals-kp-1.16.0`). Everywhere the identifier is *stored* or *put in a
   URL* it is the **slug** — the name minus the `infores:` prefix (`drugapprovals-kp`):
   the `k` field on edge docs, pool doc ids, pool index keys, and the route
   `/drugapprovals-kp/random` (the full `infores:` form is also accepted; the route strips
   the prefix). The server derives canonical ↔ slug both ways from the config table.
   `version.Parse`, `Codec.split_key` and `Display.name_of` already tolerate the colon
   (the split is at the hyphen before the numeric version segment).
2. **Version-scoped random is in**, so each KG's releases get their own random pool:
   `/drugapprovals-kp/random?version=1.16.0` and a clickable version pill on `/`.
3. **`linkouts purge` gets added** (wipe container / drop one release) — useful for the
   wipe-and-reload this change requires and later data ops.
4. **Storage is minimized and compute moves to the server** (review feedback): Cosmos
   stores only raw facts (blobs, id samples, counts); the Phoenix app derives
   names, ordering, weights and layout. Numbers and citations in "Verified cost model".

Also addressed: portal showing "no ingest storage" — the container is provisioned with
**indexing mode `none` deliberately** (zero index storage is the goal; see "Indexing & the
portal"). If the portal shows zero **data** storage, no load has hit the cloud account
yet — dev loads ran against `--store file:`. `linkouts status` (new) answers both from the
command line.

## DB design (senior-engineer pass, cost-driven)

Two governing principles, both from the feedback:

1. **Store the minimum facts; derive everything else on the server.** Cosmos holds raw
   evidence (edge blobs), per-release id samples and per-release counts. Every
   aggregation, ordering, naming, weighting and layout decision happens in the Phoenix
   app (Elixir), never in the database and never precomputed into storage.
2. **Every read is a point read; nothing is indexed; items stay small.**

### Verified cost model (Microsoft docs, confirmed this pass)

| fact | source | consequence for this design |
|---|---|---|
| point read = **1 RU per 1 KB item** (100 KB = 10 RU); item size is the *only* factor | optimize-cost-reads-writes | small pool docs and small edge docs are the whole game |
| insert ≈ **5.5 RU per 1 KB item *without* indexing**; replace = 2× insert; write RU scales with size + indexed-property count | optimize-cost-reads-writes | indexing off already minimizes write RU; keep items small |
| indexing mode `none` = "a container used as a **pure key-value store** without secondary indexes" | index-policy | this container is exactly that — the documented best fit |
| default automatic indexing overhead ≈ **10–20% of item size** in storage, plus write RU | optimize-cost-storage | `none` saves that 10–20% *and* the per-write index cost |
| with mode `none`, the only efficient retrieval is **by id** (`ReadItem`) | index-policy + corroborating SO answer | every route must resolve to a known doc id → pool-doc design |
| partition key needs no index (and ours *is* `/id`) | index-policy | `/id` PK + mode none = point reads at 1 RU/KB, zero index storage |
| items should be **≤ 2 MB**; bigger data → split into subitems anchored by a common id | optimize-cost-storage | per-(kg,version) pool subitems anchored by the reserved id prefix |
| storage **$0.25/GB/month**; free tier = **1000 RU/s + 25 GB** | optimize-cost-storage, understand-your-bill | whole account fits free; cost target ≈ $0 |
| TTL requires indexing (cannot run with mode `none`) | index-policy | no TTL; `linkouts purge` is the expiry mechanism |

**Is this the best model? Yes, for this workload** — the access pattern is a fixed set of
key-value lookups (edge by UUID, pool by kg+version, index by reserved id), so a
key-value-shaped container (PK `/id`, indexing `none`) is the cheapest possible Cosmos
configuration: no index storage, minimum write RU, 1 RU/KB reads. Alternatives checked
and rejected:

- **Turn indexing on to query `WHERE k = @kg`** — adds 10–20% storage + write RU to every
  doc forever, and a cross-partition query is the most expensive read class; the pool docs
  answer the same question with one point read.
- **Serverless capacity mode** — bills per RU consumed (~$0.25/million RU) and does not
  carry the free-tier 1000 RU/s allowance; provisioned-with-free-tier is $0 here.
  Revisit only if traffic ever exceeds 1000 RU/s (then autoscale) or drops to near zero
  (then serverless).
- **Repartition by `/k`** — would make per-KG random a query (or a scan) instead of a
  point read; strictly worse.
- **Analytical store (Synapse Link)** — adds ingest + storage charges for query analytics
  nobody runs; stays off.

What would change the model: a real search feature (subject/object CURIE lookup) would
need selectively `includedPaths` on those fields only; sustained >1000 RU/s needs
autoscale. Neither is in scope now.

The pool-doc pattern stays (CLI reservoir-samples ids while streaming a load — free, it is
already touching every edge; the app point-reads the result), extended per KG and per
version.

### Documents

**Edge docs** (unchanged shape + one field):

```json
{ "id": "575af3e8-…", "b": "KLUv…", "d": 1163284273, "k": "drugapprovals-kp" }
```

`k` = the KG **slug** — the infores name with the `infores:` prefix dropped
(`version.Parse(key).KG` minus prefix). Storing the slug instead of the full
`infores:drugapprovals-kp` halves the field (~16 B vs ~30 B/doc); the **server** derives
the canonical name (`"infores:" <> slug`, confirmed against the config table) and the URL
form from it. Not indexed (never queried — it exists for tooling, Data Explorer
inspection, and one `includedPath` if a query is ever enabled). Kept far under the 1 KB
point-read RU step. Set on create; the 409-merge path keeps the existing value (a blob can
hold versions of two KGs; first writer wins — documented in ADR 0001).

**Pool docs** — one per (kg, version), **existing `edgelinkouts.pool/1` format verbatim**,
at a reserved id built from the slug:

```
id: __random_pool__:drugapprovals-kp:1.16.0
body: {"schema":"edgelinkouts.pool/1","key":"infores:drugapprovals-kp-1.16.0","sampled_at":"…","ids":["575af3e8-…", …]}
```

**Packed ids were measured and rejected.** The earlier draft of this plan proposed storing
ids as base64 of sorted 16-byte UUIDs with delta+varint, on the reasoning that hex strings
waste bits. Measured with the real codec (`cmd/poolbench`, zstd level 3, no dictionary,
random v4 UUIDs, bytes of the stored `b` field per id):

| ids | cap 256 | cap 512 | cap 1024 | cap 4096 | B/id |
|---|---|---|---|---|---|
| hex strings (pool/1) | 7 032 B | 13 812 B | 27 500 B | 109 832 B | **26.8** |
| base64 of 16-byte binary | 7 464 B | 14 744 B | 29 308 B | 116 692 B | 28.5 |
| + sorted delta varint | 7 180 B | 13 948 B | 27 496 B | 108 980 B | 26.6 |

Binary packing is **worse** (base64's 6-bit alphabet entropy-codes less efficiently under
zstd's byte-level FSE than 4-bit hex does, so the 33% base64 inflation is never recovered),
and delta-varint buys 0.6% — because deltas between *random* 128-bit UUIDs are themselves
≈118 bits, not the few bytes delta encoding assumes. So ids stay hex strings, the pool wire
format does not change at all, and no pack/unpack codec, dual-format reader, or fuzz target
is needed. The real levers are the cap (linear) and the server-side cache (below).

**Pool index** — the old `__random_pool__` id is repurposed as a tiny metadata doc (new
schema `edgelinkouts.pool_index/1`, **no ids, only counts**, keys are slugs):

```json
{ "schema": "edgelinkouts.pool_index/1",
  "kgs": { "drugapprovals-kp": {
      "versions": { "1.11.2": {"edges": 130211, "sampled": 1024}, "1.16.0": {"edges": 129807, "sampled": 1024} } } } }
```

### Why docs-per-pool (not one big pool doc)

A single pool doc holding every version's ids grows linearly per release, and every
random read pays for **all** versions' ids (RU scales with item size). With docs per pool,
each request reads only what it needs; the design is unbounded in versions/KGs with
**constant per-request cost**:

RU is item size / 1 KB, so these are the measured cold numbers (cap 1024 → pool ≈ 27 KB):

| route                  | reads                        | cold RU          | warm RU |
|------------------------|------------------------------|------------------|---------|
| `/` bar                | index (< 1 KB)               | ~1               | 0       |
| `/random` (global)     | index → weighted pool        | ~1 + ~27         | 0       |
| `/<slug>/random`       | index → weighted pool        | ~28              | 0       |
| `/<slug>/random?v=`    | pool only (~27 KB)           | ~27              | 0       |
| `/edges/:id`           | edge doc (0.6–31 KB measured)| ~1–31 (median ~2)| ~1–31   |

Warm = within the server-side cache TTL. The index and the decoded pools are cached in
`Dedupe` with a per-call 15-min TTL, so a pool is read **once per node per 15 min**,
however many randoms are served: amortized cost per random ≈ 27 RU / hits-per-TTL ≈ 0.
That cache is also where the compute shift lands — decode, weighting, ordering and slug
mapping all happen in the app process, not per request against Cosmos. Edge docs stay on
`Dedupe`'s default 30 s TTL (they are the served product and must not go stale).

The cap is the one knob that trades randomness variety for cold-read RU: 1024 ids ≈ 27 RU,
256 ids ≈ 7 RU. 1024 is the default (a reviewer clicking "random" should not see repeats);
drop `--sample-size` if cold RU ever matters.

Global and per-KG random pick a version **weighted by `edges`** (true distinct edge count
offered for that release) then a uniform id in that release's reservoir → uniform over
edges, exact as long as each reservoir sample is uniform (reservoir sampling guarantees
that). Approximation when a key is loaded twice: `edges` = max of runs — documented.

### Storage minimization decisions

- **Ids stay hex strings** — measured (table above): packing is a net loss, delta is noise.
  No new codec, no dual-format reader.
- **Reservoir default 4096 → 1024 per pool doc**: a 4× cut in pool storage and cold-read
  RU, and 1024 distinct targets per release is far beyond what "surprise me" needs.
  `--sample-size` still overrides; pool size is linear in it.
- **Ids stored exactly once.** No global flat id list anywhere (it would duplicate
  per-version ids, and there is no cross-document compression to recover it). The index doc
  holds counts only — under 1 KB.
- **Subitem split keeps every doc small.** Microsoft's ≤ 2 MB item guidance is satisfied by
  construction: pools are split per (kg,version) anchored by a common reserved id prefix, so
  no doc grows with the number of releases or KGs, and a random never pays for releases it
  did not ask about.
- **Indexing `none` saves the 10–20% index overhead** on top of data (documented Cosmos
  default-indexing cost), plus index-write RU on every write.
- **`k` stores the slug, not the full infores** (~16 B/doc saved). At the measured fixture
  sizes that is ~2 MB per 130k edges — small, but free to take.
- **No duplicated content anywhere.** Nothing derived (display names, version order, latest
  tags, weights, page HTML) is ever stored — the server recomputes it from `kgs/*.exs` +
  the counts.
- **Storage budget, measured not guessed.** Contract fixtures (6 real DAKP edges, no
  dictionary): stored docs are 861 B – 31 717 B, mean ≈ 7.1 KB, median ≈ 1.5 KB. So a
  130k-edge KG is ≈ 200 MB – 1 GB depending on release overlap and dictionary training;
  `k` adds ≈ 4 MB; pools ≈ 2 × 27 KB; index < 1 KB. At $0.25/GB/month that is
  **≈ $0.05–0.25/month**, and the 25 GB free tier covers ~25–100× this KG. Adding a KG or
  a release adds one ~27 KB pool doc + one index entry: **linear storage, constant
  per-request cost** — the scalability property.

### Compute placement (server, not DB, not storage)

- CLI at load (free, already streaming): sample ids, sort them, write counts.
- Cosmos: zero compute — point reads only, no queries, no stored procedures, no indexes.
- Phoenix server (cheap, cached): decode pool ids, slug ↔ infores mapping, version
  ordering (`Codec.compare_versions`), latest-tag from config `latest_version`,
  weighted-by-`edges` random selection, bar row assembly.
- Browser: only pixel measurement for the `…` overflow chip (unavoidable; no other
  client-side logic).

### Indexing & the portal ("no ingest storage")

- Container settings after `linkouts init` (unchanged by this work, and correct):
  partition key `/id`, **indexing mode `none` (Automatic off, no paths)**, manual
  1000 RU/s on the database, analytical/Synapse store off. Microsoft documents mode
  `none` as the setting for "a container used as a pure key-value store without secondary
  indexes" — this container is exactly that. **Zero index storage in the portal is the
  goal, not a missing index.** Do not turn indexing on: it would add 10–20% storage and
  write RU on every load for queries this app never issues.
- Documents are stored regardless of indexing, so **0 *data* storage means the account
  genuinely has no items** — every load so far ran with `--store file:` (dev, `make
  local-load` writes `tmp/…ndjson`). This is the likely explanation for the portal
  reading; the verification below distinguishes "nothing loaded" from "indexing off".
- **How to check storage precisely** (documented Cosmos mechanism): read the container
  and inspect `x-ms-request-usage` / `x-ms-request-quota` (GB used / quota, index size
  included), or portal Metrics → *Storage* (data vs index) + Data Explorer item count.
  New small CLI surface for this: `linkouts status` prints item-level facts — storage
  usage from those headers, doc counts by kind (edges / pools / index) and the measured
  RU of one probe read — so "is my data actually in Cosmos, and what does it cost" is a
  one-command answer instead of a portal hunt.
- TTL is deliberately not used: it requires indexing (incompatible with mode `none`);
  `linkouts purge` is the deletion path.

## Web design

- `GET /` — `PageController.home` renders a real page from one point read of the pool
  index: KG rows (display name via `Display.get/1`, fallback raw name; row → click =
  `/<slug>/random`) with version pills (newest first, latest highlighted per config
  `latest_version`), pill links carry `?version=<label>`, `…` overflow chip. Legacy
  `/?id=<uuid>` redirect unchanged. Empty index → friendly empty state; store error →
  page with a notice line. Static render + tiny JS — no LiveView (same reasoning as
  `/random`).
- `GET /:kg/random` (+ optional `?version=`) — `RandomController`: strip optional
  `infores:` prefix from `:kg`; with version → direct pool doc read, 302 to
  `/edges/<id>?version=<kg>-<label>` (opens that release directly); without → index +
  weighted pool. Unknown KG/version/empty pool → 404 (`:unknown_kg` template). Error
  mapping (rate-limited/store down) shared with today's `/random`.
- Header "Random edge" button — `Layouts.app` reads optional `kg_slug` assign
  (`assign_new/3`); `EdgeLive` assigns `Codec.kg_name/1` of the current version key →
  button href `~p"/#{kg_slug}/random"`, else `/random`. Edge-page KG label also links to
  `/<slug>/random`.
- Slug helpers on `Display`: `slug/1` (strip `infores:`) and `kg_from_slug/1` (canonical
  name for a slug, via the config table; falls back to `"infores:" <> slug`). Used for
  URLs, for matching the incoming `:kg` param, and for expanding the stored `k` field.
- Server-side caches (`Dedupe.execute/4` with a per-call `ttl_ms` of 15 min): the pool
  **index** (read by every `/`, `/random` and kg-random — the hottest doc) and **decoded
  pools** (so decoding the frame happens once per node per TTL, not per request). This is
  where the "shift compute to the server" lands: Cosmos sees ~1 read per TTL per pool
  instead of one per request. Edge docs stay on the default 30 s TTL (data correctness; they
  are the served product and each is one ~1 RU read). Reusing `Dedupe` rather than adding a
  `:persistent_term` layer keeps one cache mechanism, one eviction path and one place a test
  can turn caching off (`dedupe_ttl_ms: 0` in `config/test.exs` disables every override, so a
  caller cannot switch it back on behind a test's back).
- Reader tolerance: a leftover pool/1 doc at `__random_pool__` (pre-change format) is
  treated as "no index" → `/` shows the empty state, `/random` 404s, until the reload.
  No half-migration; docs are wiped and reloaded anyway.

## CLI: `linkouts purge`

Store interface gains `Delete(ctx, id)` and `All(ctx, fn(Doc) error)` (paginated
cross-partition scan; azure/file/mem/fake implementations + tests).

- `linkouts purge --all` — cosmos: drop and re-provision the container (instant, zero
  RU); file/mem: truncate. The wipe-and-reload this change requires.
- `linkouts purge --key <kg-version>` — delete that release's pool doc + index entry,
  then scan all edge docs: remove that version key from each blob (`codec` needs a
  `RemoveVersion`), delete blobs that become empty, rewrite the rest under etag
  precondition. Cross-partition scan is RU-heavy — admin op, prints progress and total
  RU. (Per-KG variant `--kg <name>` = same over that KG's keys.) This is the future-useful
  op (drop a bad release without nuking everything) — implemented, documented as heavy.

## Files to modify

CLI (Go):

- `cli/internal/cosmos/store.go` — `Doc.KG` (`json:"k,omitempty"`, slug); `Delete` + `All`
  on the `Store` interface; pool doc id scheme (`PoolDocID(slug, version)`), index id
  stays `RandomPoolID`; `Status`/storage-usage read for `linkouts status`.
- `cli/internal/codec/blob.go` — `PoolIndex` struct + schema const
  `edgelinkouts.pool_index/1`; `RemoveVersion` on `Blob` for purge. `Pool` itself is
  unchanged (measured: hex ids beat packing).
- `cli/internal/pipeline/load.go` — parse KG/version once (`Options.KG`,
  `Options.VersionLabel`); set `Doc.KG` (slug); `writePool` → per-(kg,version)
  pool doc + index merge; default `SampleSize` 4096 → 1024.
- `cli/cmd/linkouts/{purge.go,status.go,probe.go,load.go}` — new purge command; new
  `status` command (storage usage from `x-ms-request-usage`/`-quota`, doc counts, one
  measured probe read); probe reads ids via the index; load docs text updates.
- `cli/internal/cosmos/{azure,file,fake}.go` — Delete/All implementations.
- `cli/internal/pipeline/load_test.go`, `load_poolctx_test.go`, new `purge_test.go`,
  codec tests for `PoolIndex`/`RemoveVersion`.
- `cli/testdata/contract/*` — regenerated via `make contract` (load keys change to
  infores form).
- `Makefile` — `FIXTURE_KEY`-style targets: `drug-approvals-kg-*` → `infores:drugapprovals-kp-*`.
- Docs: `docs/adr/0001-wire-format.md`, `docs/pages/storage-format.md`,
  `docs/cli/linkouts_{load,init,purge,status}.md`, `docs/pages/ingest.md`,
  `docs/pages/deployment.md` (indexing/index-storage explanation, storage check,
  reload runbook).

Web (Elixir):

- `kgs/drug_approvals.exs` — `name: "infores:drugapprovals-kp"`.
- `web/lib/edge_linkouts/codec.ex` — `decode_pool_index/2` (new schema).
- `web/lib/edge_linkouts/cosmos.ex` — `pool_doc_id/2` (slug-based), decode helpers for
  both pool schemas; `__random_pool__` stops being special (it is now just the index doc
  id, read like any other doc).
- `web/lib/edge_linkouts/cosmos/{fake,file,http}.ex` — `random_pool/0` callback replaced
  by plain point reads through `get_edge/1` (the behaviour simplifies to one callback).
- `web/lib/edge_linkouts_web/edges.ex` — `fetch_pool_index/0` + `fetch_pool/2`, both
  behind the 15-min `Dedupe` TTL; the decoded pool (ids + key + sampled_at) is what is cached.
- `web/lib/edge_linkouts_web/router.ex` — `get "/:kg/random", RandomController, :random`.
- `web/lib/edge_linkouts_web/controllers/random_controller.ex` + `random_html/unknown_kg.html.heex`.
- `web/lib/edge_linkouts_web/controllers/page_controller.ex` + `page_html.ex` +
  `page_html/{home,kg_bar}.html.heex` (new view + templates).
- `web/lib/edge_linkouts_web/components/layouts.ex` — `kg_slug`-scoped random button.
- `web/lib/edge_linkouts_web/live/edge_live.ex` — assign `kg_slug`; KG label link.
- `web/assets/js/app.js` (overflow JS), `web/assets/css/app.css` (`.kg-bar`; reuse
  `.chip`, `.version-pill`, `.chip-more`).
- Tests: `random_controller_test.exs`, `page_controller_test.exs`, `edge_live_test.exs`,
  `contract_test.exs`, `cosmos_fake_test.exs`, `cosmos_file_test.exs`; Fake seed helpers
  for index + pool docs.

## Reuse

- `version.Parse` (`cli/internal/version/version.go`) — KG prefix + version label.
- `reservoir` (`cli/internal/pipeline/sample.go`) — already per-load (one load = one
  kg+version), so per-pool docs fall out naturally; merge = re-reservoir old ∪ new. Its
  `snapshot()` already sorts, which keeps a seeded run byte-reproducible.
- `Codec.canonical/1` + zstd/dict envelope — pool docs reuse the same framing as blobs.
- `Edges.read/2` dedupe + error mapping — new reads use the same funnel.
- `Display.get/1`, `Config.display_name`, `latest_version`, `Codec.kg_name/1`,
  `Codec.compare_versions/2` — bar labels, latest pill, slug mapping, version order.
- `.chip`, `.chip-row`, `.chip-more`, `.version-pill`, `.latest-badge` CSS; `state-page`
  empty/busy/unavailable templates.
- `linkouts probe` — the existing instrument for measuring real RU/doc sizes post-load.

## Steps

1. CLI: `Doc.KG` (slug), KG/version parsed in `normalize`, set in `process`, preserved in
   `merge`.
2. CLI: `PoolIndex` codec; per-(kg,version) pool doc + index merge in `writePool`;
   sample default 1024.
3. CLI: `linkouts purge` (`--all`, `--key`) + `Delete`/`All` on all four store backends;
   `codec.RemoveVersion` for blob prune. `linkouts status` (storage headers + counts).
4. Regenerate contract fixtures (`make contract`) with infores load keys; update golden.
5. Web: config rename `name:`; `Codec.decode_pool_index`,
   `Cosmos.pool_doc_id/2`; behaviour simplified to `get_edge/1`; Fake/File seeds
   (index doc + per-version pool docs).
6. Web: router + `RandomController` scoped random (`?version=` fast path, weighted pick,
   `:unknown_kg`); tests.
7. Web: `PageController.home` bar page (`PageHTML`, templates, slug helper); overflow JS
   + CSS; tests.
8. Web: `kg_slug` in `EdgeLive`, scoped header button; `Edges` 15-min caches for index +
   decoded pools; tests.
9. Docs: ADR 0001, storage-format, cli reference, ingest, deployment runbook (indexing
   explanation + portal checks + reload steps), README.
10. Full gate: `go test ./...`; `cd web && mix precommit`; manual `make local-load &&
    make local-web` click-through.

## Verification

- `cli`: `go test ./...`; `make contract` byte-stable with fixed seed; `purge --all` on a
  mem store round-trips; `purge --key` leaves other versions intact (fake store).
- `web`: `mix precommit`.
- Local file backend (`make local-load && make local-web`):
  - `/` shows `Drug Approvals KP` row + version pills `1.16.0  1.11.2`, latest
    highlighted; narrow window → `…`, click expands.
  - `/drugapprovals-kp/random` 302s to an edge whose version keys are all
    `infores:drugapprovals-kp-*`; repeated hits never leave the KG.
  - `/drugapprovals-kp/random?version=1.11.2` lands **on** a 1.11.2 version page
    (URL carries `?version=infores:drugapprovals-kp-1.11.2`).
  - Edge page header button → `/<slug>/random`; `/` header button → `/random`.
  - `/nosuchkg/random` → 404; `/drugapprovals-kp/random?version=9.9.9` → 404.
  - NDJSON line for one edge contains `"k":"drugapprovals-kp"`; pool doc id
    `__random_pool__:drugapprovals-kp:1.16.0` decodes as pool/1; index doc has
    per-version counts; pool doc ≤ ~30 KB at the default cap.
- Cloud reload: `linkouts purge --all` → `linkouts init` → re-run loads →
  - `linkouts status`: storage usage (`x-ms-request-usage`) > 0, index usage 0, item
    count ≈ edges + 1 index + N pools; one probe read ≈ 1 RU.
  - Data Explorer / portal Metrics → Storage: **Data** > 0 (≈ tens of MB), **Index** = 0
    by design, analytical store off.
  - `linkouts probe` reports edge-doc point reads ≈ 1 RU and pool reads ≈ 1 RU.
  - Interpretation of the original report: "no ingest/index storage" is the expected
    result of indexing mode `none`; if **Data** storage is also 0, the loads never reached
    this account/container (they ran with `--store file:`).

## Notes / assumptions

- The infores value is used exactly as stated (`infores:drugapprovals-kp`). If the
  published id differs (e.g. has a `multiomics-` prefix), it is a one-line change in the
  config name + Makefile load keys + regenerated fixtures.
- Pool ids stay hex UUID strings: base64/binary packing and delta-varint were both
  measured and are worse-or-equal under zstd (`cmd/poolbench`, table in "Documents").
- Old data is deleted, never migrated: `purge --all` (cloud) / regenerate NDJSON (dev,
  fixtures). Pre-change docs/pool are simply absent after the reload.

## Implementation record

Built and verified as planned, with four deviations worth keeping:

- **Cache mechanism**: `Dedupe.execute/4` gained an `opts` argument (`:ttl_ms`) instead of a
  new `:persistent_term` layer. Same amortisation (one read per node per 15 min), one cache
  mechanism instead of two, and the test config's `dedupe_ttl_ms: 0` still disables all of it.
- **Download filenames**: a canonical version key contains a colon, which is illegal in a
  Windows filename and made `send_download` emit both `filename="…%3A…"` and `filename*=`.
  `EdgeController.filename_key/1` now maps unsafe characters to `-`, so the attachment is
  `edge-<uuid>-infores-drugapprovals-kp-1.16.0.ndjson`. The body and `?version=` keep the
  canonical key.
- **`COSMOS_BACKEND=file` now wins in dev.** `config/runtime.exs` used to pick the HTTP backend
  whenever credentials were in the environment, so `COSMOS_BACKEND=file COSMOS_DOCS=… mix
  phx.server` quietly read the real Azure account. A `cond` makes an explicit `file` override
  the environment.
- **Pool reads retry instead of failing.** A release listed by a cached index whose pool has
  since been purged is skipped and the weighted pick is made again (up to 3 tries), so a
  working store never 404s because one entry went stale.
- **The REST client signs the raw resource id.** `EdgeLinkouts.Cosmos.HTTP` was signing the
  percent-encoded resource link, so every document whose id needs escaping — the reserved pool
  docs, whose ids carry colons — 401'd against the live account while UUID ids kept working.
  `doc_links/2` now returns the URL form and the signature form side by side (ADR 0002 has the
  note; three tests pin both forms).
- **Progress lines carry live RU.** The load's progress line printed `ru=0.0` for an entire run
  because `Stats.RU` was only filled at the end; the reporter now reads the budget at report
  time (the 1.16.0 reload showed `674935.3 RU spent` in the final summary while every progress
  line said 0.0).

Verified against a local file backend holding the regenerated contract fixtures (9 documents:
6 edges, 2 pools, 1 index):

- `/` renders one row: `Drug Approvals KP`, `infores:drugapprovals-kp`, `2 releases · 6 edges
  in 1.16.0`, pills `1.16.0` (latest, highlighted) and `1.11.2`, `data-kg-pills` +
  `data-kg-more` present, header button `/random`. Costs one point read of `__random_pool__`.
- `/random` → 302 `/edges/<uuid>?version=infores%3Adrugapprovals-kp-1.16.0`.
- `/drugapprovals-kp/random` → 302 inside the KG; 20 draws stayed inside it.
- `/drugapprovals-kp/random?version=1.11.2` → 302 with the 1.11.2 key; 20 draws landed only on
  that release's 6 pool ids; the edge page opens on `version 1.11.2` with no `latest` badge.
- `/infores:drugapprovals-kp/random` (full infores form in the path) → 302, same behaviour.
- `/nosuchkg/random` → 404 `No random edge in infores:nosuchkg`;
  `/drugapprovals-kp/random?version=9.9.9` → 404 `No random edge in Drug Approvals KP 9.9.9`.
- Edge page header button and the KG name both link to `/drugapprovals-kp/random`; the external
  source keeps its own icon link beside the name.
- `linkouts status --check-pools` on that store: 9 documents = 6 edges + 2 pools + 1 index,
  both releases `6 edges · 6 sampled`, each pool 488 B.
- Gates green: `make check` (Go + 146 Elixir tests, credo, gofumpt, 23 s of a 60 s budget),
  `mix precommit`, `make precommit` (prek, all files), `make docs` with
  `--warnings-as-errors`, and `make contract` byte-reproducible across runs.

Outstanding, and it needs a decision rather than code: **the live Azure container still holds
the pre-change `__random_pool__` document** (`edgelinkouts.pool/1` where an index is expected).
A dev server pointed at that account logs `{:schema, "edgelinkouts.pool/1",
"edgelinkouts.pool_index/1"}` and the app answers "the store did not answer" on `/` and 404 on
`/random` — the tolerance path from "Reader tolerance" above, working as designed. Clearing it
is `linkouts purge --all --yes` followed by `linkouts init` and the reloads, which deletes
stored data; that is a destructive cloud operation and is not run here.

Resolution: the user asked for the wipe. `linkouts purge --all --yes` ran on 2026-10-05
(container deleted and re-created with partition key `/id`, indexing `none`), then
`infores:drugapprovals-kp-1.16.0` was loaded — 131,678 edges in 26m04s at 84 edges/s,
674,935 RU (450 RU/s ceiling, 131,481 paced waits, ~5.1 RU per document), 178.1 MiB raw →
126.9 MiB stored. Post-load: `status --check-pools` reports one graph, one release,
131,678 edges, pool 26.8 KiB / 1024 ids; `probe --n 20` reads at a mean of 1.00 RU (worst
1.05); `/`, `/random` and the scoped routes 302 to real edges through the live account once
the signing fix above was in — the first post-reload web reads were exactly what exposed it.
