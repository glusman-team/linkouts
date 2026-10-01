# PLAN — edge-linkouts monorepo (Go CLI → Azure Cosmos DB → Phoenix LiveView)

App `edge-linkouts` · host `linkouts.skyelanegoetz.com` · Fly region `lax` · Cosmos free tier (1000 RU/s, 25 GB) in West US 2.

**This pass:** build everything and verify it locally on a new branch — no GitHub repo, no push, no Fly, no Cloudflare, no cloud spend. Deploy artifacts are written but dormant. Five ⛔ STOP points mark where I hand over to you; see **Build sequence**.

## Context

The repo is `KGinfo.pl` (Perl CGI), `KGindexQuery.py` (SQLite trial lookup) and `KGinfo/*.pl` — one imperative Perl module per KG, each hard-coding `graphName`, `datasetDescription`, `edgeDescription`, `evidence`, `feedback`, plus an `addLinkout` switch mapping CURIE prefixes to URLs. Adding a KG means writing Perl; there are no tests. All three are deleted once ported.

Replacement: a Go/Cobra CLI that ingests KGX `nodes.ndjson` + `edges.ndjson` into Cosmos DB, and a minimal Phoenix LiveView app on Fly.io that renders one edge by UUID with version switching, all display text driven by declarative `.exs` configs in `kgs/`.

Measured from `~/Desktop/dakp-latest/drug_approvals_kg_*_v1.11.2.ndjson` (source of the test fixtures): 110,454 edges / 15,228 nodes; edge bytes min 868, median 1,099, p90 1,303, max 59,553. Predicates: `biolink:applied_to_treat` (83,808), `biolink:contraindicated_in` (15,055), `biolink:treats` (11,591).

## Repo layout

```
├── cli/          Go module github.com/glusman-team/edge-linkouts/cli  (go 1.26, no CGO)
├── web/          Phoenix 1.8.15 app  EdgeLinkouts / EdgeLinkoutsWeb
├── kgs/          declarative display configs — the only dir contributors normally edit
├── docs/         ExDoc project (guides + generated CLI reference)
├── .github/workflows/{ci,docs,deploy}.yml
├── fly.toml  Dockerfile        (repo-root build context so kgs/ is compiled in)
├── Makefile  .pre-commit-config.yaml  .envrc (gitignored)  .envrc.example  README.md
```

## Storage: one document per edge UUID

Container `edges`, database `edge_linkouts`, **partition key `/id`**, indexing policy
`{"indexingMode":"consistent","automatic":true,"includedPaths":[],"excludedPaths":[{"path":"/*"}]}`
(only `id`/`_ts` indexed → cheapest writes; point reads unaffected). Throughput 1000 RU/s manual. CLI uses the primary key; web uses the **read-only** key.

```json
{ "id": "575af3e8-8015-3718-be03-4da18a0bacfc", "b": "KLUv/QAMAdw…" }
```

`b` = base64 of **one zstd frame** containing canonical JSON of the whole version map:

```json
{
  "drug-approvals-kg-1.11.2": { "subject": "CHEBI:64019", "predicate": "biolink:treats", "…": "…" },
  "drug-approvals-kg-1.12.0": { "$t": "drug-approvals-kg-1.11.2",
                                "$set": {"clinical_approval_status": "approved_for_condition"},
                                "$add": {"publications": ["PMID:40123456"]},
                                "$del": ["number_of_cases"] }
}
```

- **Key format `<kg>-<version>`** (`multiomics-kg-1.12.0`). Tablassert UUIDs are deterministic (`uuid3` over sorted key/value parts), so the same assertion keeps its id across versions and across KGs; the key carries the KG name, and the display config is selected by parsing it off the key. Nothing per-KG is stored on the edge.
- One frame per doc: zstd dedupes near-identical versions by itself, base64's 33% overhead is paid once, and a page view is a single decode. Cost: no per-key `PatchItem` — every write is a whole-doc read-modify-write, which is the repack behaviour we want.
- Patch verbs: `$t` (template base — must be a *full* version of the same KG, so materializing is one map merge), `$set` (override/create), `$add` (append to list-valued keys, dedup, order preserved), `$del` (remove). KGX slots never start with `$`.
- Encoder tries every full version as base and keeps the smallest compressed result; an unchanged edge becomes `{"$t":"…"}` ≈ 12 bytes. `--cross-kg-templates` exists, default off.
- **zstd dictionary per KG**, trained from ~20k sampled edges, stored as doc `__zdict__<kg>` in the same `{id,b}` shape. The dictID rides in every frame header, so the reader picks the dictionary from the frame; web caches it in `:persistent_term`.
- Sidecar doc `__random_pool__` backs `/random` (see Web).

**Write path.** `CreateItem` first (no read). On **409** → point-read → decode → merge new key → re-derive the optimal encoding for *all* versions (**repack**, default) → `UpsertItem` with the ETag precondition, one retry on 412. `--no-repack` adds the key without re-deriving old deltas.

**Budget.** 450 RU/s per app (45% each, 10% headroom for the portal/retries), both env-tunable. Median edge ≈ 6–7 RU (create 5.7, later versions +1 for the read) → ~65 edges/s → 110k edges in ~30 min. Page views are ~1 RU point reads. `linkouts probe` measures real RU before a big run.

## CLI

```
linkouts init                                   # idempotent db + container + policy + throughput
linkouts load --nodes N --edges E [--kg K --version V] [--key K-V] [--no-repack]
              [--ru-budget 450] [--workers NumCPU] [--senders 8] [--zstd-level 7]
              [--dry-run] [--out docs.ndjson] [--sample-size 4096] [--cross-kg-templates]
linkouts get <uuid> [--key K-V] [--raw]         # decode + materialize; contract oracle
linkouts probe [--n 50]                         # measure RU per create/read/upsert
linkouts rig --from X.RIG.yaml --out kgs/x.exs  # scaffold meta: from a Tablassert RIG
linkouts docs --out ../docs/cli                 # cobra/doc markdown (hidden)
```

`--kg`/`--version` are inferred from Tablassert filenames (`drug_approvals_kg_edges_v1.11.2.ndjson` → `drug-approvals-kg-1.11.2`); `--key` overrides.

```
cli/cmd/linkouts/{main,init,load,get,probe,rig,docs}.go
cli/internal/config/config.go        flags + env → Config (endpoint, db, container, key, budgets)
cli/internal/engine/engine.go        type Engine interface { Join(ctx, nodes, edges string) (io.ReadCloser, error) }
cli/internal/engine/chdb.go          embedded chdb session; max_threads = NumCPU
cli/internal/engine/join.sql         //go:embed
cli/internal/codec/canonical.go      CanonicalJSON — recursively sorted keys, compact, no nulls
cli/internal/codec/delta.go          BestDelta(base…, new) Patch · Apply(base, Patch)
cli/internal/codec/blob.go           EncodeBlob(map) (b64, dictID) · DecodeBlob(b64, dictID)
cli/internal/codec/dict.go           BuildDict(samples) via zstd.BuildDict; dict doc id
cli/internal/cosmos/cosmos.go        type Client interface { CreateItem, ReadItem, UpsertItem(etag), GetBlob }
cli/internal/cosmos/{azcosmos,fake,provision}.go
cli/internal/ratelimit/ru.go         RU token bucket + Reconcile(actualRU)
cli/internal/pipeline/{pipeline,sample,progress}.go
```

**Join (embedded ClickHouse).** `github.com/ClickHouse/clickhouse-go/v2` is a driver for a running *server*; the bundling package is `github.com/chdb-io/chdb-go/v2` v2.2.0 + `import _ "github.com/chdb-io/chdb-go/lib/embedded"` v0.260703.1 (zstd-compressed `libchdb` per platform, linux-amd64 payload ≈ 117 MB, extracted once to `CHDB_CACHE_DIR`, `dlopen`ed via `purego` — no CGO, nothing to install). Queries stream (`QueryStreaming`), so a 134 MB file never buffers. No subprocess backend.

`join.sql` reads edges as a ClickHouse `JSON` column (everything stays JSON), hash-joins nodes on `subject` and `object`, builds `{subject_name, subject_category, object_name, object_category}`, filters that map through Tablassert's `keep()` rule — drop `null`, `""`, `[]`, `{}` and strings whose trimmed lowercase form is `na|nan|null|none`; **keep `false` and `0`** — then `jsonMergePatch`es it onto the edge and emits streamed `JSONEachRow`. The `JSON` type never stores null paths and the joined fields are filtered, so nulls cannot appear; a test asserts it.

**All cores.** `runtime.NumCPU()` sets the chdb `max_threads`, `--workers`, and `GOMAXPROCS` together. Each worker owns its `zstd.Encoder` and parse buffers — no shared mutable state, no lock contention. The only serialization points are the fan-in channel handoff and `limiter.WaitN`, which sleeps off-CPU. CPU work is ~50–100 µs/edge against a ~10–30 ms network wait, so the RU budget is the only ceiling.

**Pipeline** (every channel bounded → flat memory): stream joined lines → reservoir-sample UUIDs (`__random_pool__`) and edges (dict training, first run) → `NumCPU` workers (`sonic` parse → canonicalize → delta vs existing versions → zstd+dict → base64 → `WriteOp{estRU}`) → **fan-in to one channel** → single dispatcher calling `limiter.WaitN(estRU)` → `--senders` goroutines doing the create/409-merge/upsert. The real `x-ms-request-charge` is debited back into the bucket, so the budget stays honest; azcosmos handles 429/retry-after. Progress prints lines read/encoded/written, RU/s, ETA, compression ratio, bytes saved by templating.

**Deps.** `spf13/cobra` v1.10.2 (+`doc`), `chdb-io/chdb-go/v2` v2.2.0 (+`lib/embedded`), `Azure/azure-sdk-for-go/sdk/data/azcosmos` v1.5.0, `klauspost/compress` v1.20.1 (`zstd.BuildDict`, `WithEncoderDict`, `WithEncoderLevel`), `bytedance/sonic`, `golang.org/x/time/rate`, `golang.org/x/sync/errgroup`.

## Web

`mix phx.new web --app edge_linkouts --module EdgeLinkouts --no-ecto --no-mailer --no-dashboard --no-gettext`, then hand-delete what the flags leave behind.

| keep | delete |
|---|---|
| `phoenix`, `phoenix_html`, `phoenix_live_view`, `bandit` | `jason` → `config :phoenix, :json_library, JSON` (Phoenix 1.8 needs only `decode!/1`, `encode!/1`, `encode_to_iodata!/1`) |
| `finch` (the one HTTP client) | `lazy_html` → a Rust NIF; Floki 0.38.4 defaults to Mochiweb, pure Erlang |
| `nimble_options` (validates `kgs/*.exs`) | `telemetry_metrics`, `telemetry_poller` (no dashboard) |
| dev/build: `phoenix_live_reload`, `esbuild`, `tailwind`, `heroicons`, `daisyui` | `dns_cluster` (no clustering) |
| test: `floki`, `stream_data`, `credo` | `swoosh`, `req`, `gettext`, `ecto*`, `phoenix_live_dashboard` (excluded by flags) |

**6 runtime deps. No third-party NIFs.** Precision note: OTP 28's `:zstd` *is* a NIF, but it ships inside the Erlang stdlib — nothing to fetch, compile or pin, which is why zstd costs zero dependencies. `esbuild`/`tailwind` are build-time executables, absent from the release.

```
web/lib/edge_linkouts/
  cosmos/client.ex        @callback get_doc(id) :: {:ok, map} | :not_found | {:error, term}
  cosmos/finch.ex         real backend. HMAC signing: :crypto.mac(:hmac,:sha256,key,
                            verb<>"\n"<>resource_type<>"\n"<>resource_link<>"\n"<>date<>"\n")
                          |> Base.encode64 → authorization header; x-ms-version/-date,
                          x-ms-documentdb-partitionkey. ~70 LOC. [D14]
  cosmos/file_backend.ex  local backend: serves {id,b} docs from an ndjson file written by
                          `linkouts load --out`. Selected by config, no cloud, no bill —
                          this is what "local deployment" runs against
  cosmos/limiter.ex       :atomics RU token bucket, monotonic lazy refill, debited by the
                          real x-ms-request-charge; :throttled → send_after retry
  cosmos/dedupe.ex        in-flight coalescing keyed by uuid + 30 s ETS (kills the
                          LiveView static/connected double read)
  codec/blob.ex           Base64.decode → :zstd.decompress(frame, dictionary: dict) → JSON.decode
  codec/patch.ex          materialize: Map.merge($set) ++ dedup append($add) -- Map.drop($del)
  codec/dict.ex           persistent_term cache of __zdict__<kg>, lazy-fetched by dictID
  display/{config,schema,template,render,formatters,prefixes}.ex
  edges.ex                get_edge(uuid) · versions/1 · materialize/2 · diff/3
  random.ex               pool cache (persistent_term, 15 min TTL) + pick/0
web/lib/edge_linkouts_web/
  router.ex               live "/", HomeLive · live "/edges/:uuid", EdgeLive · get "/random"
  live/{home_live,edge_live,edge_components}.ex
  controllers/random_controller.ex
  components/{layouts,core_components}.ex   assets/js/app.js (copy, download-kgx, theme hooks)
```

Routes: `/` (UUID box + "surprise me"), `/edges/:uuid?v=<key>` (`push_patch`, shareable), `/random` (302), legacy `/?id=<uuid>` → `/edges/<uuid>`.

**`/random`.** Indexing is off, so a random-document query would be a full cross-partition scan. The CLI reservoir-samples up to `--sample-size` (4096) UUIDs per key into `__random_pool__`; the app point-reads it once (~16 RU), caches it 15 min, and `/random` 302s to a uniform-random UUID across **all** KGs and versions (unscoped, unlike the Perl original). Amortized ≈ 0.02 RU/s.

**Version toggle costs 0 extra reads** — the whole map arrives in one blob; after one decode, switching versions is a map lookup plus one `$t` merge. Decode runs in the calling LiveView process, so BEAM spreads it over all schedulers; blobs are ~0.5 KB (max ~20 KB), i.e. tens of microseconds, and anything over 256 KB is decoded in a `Task`.

**UI.** Server-rendered SVG edge diagram (subject → predicate → object, chips colored by `biolink:category`, qualifiers as badges, every name a linkout with a copy-CURIE button) · plain-English statement from the KG config · evidence panel driven by config `viz` hints (`clinical_approval_status` pill, `FDA_regulatory_approvals` linkouts, `number_of_cases` count bar, effect size as a diverging bar centered on 0, p-value as a −log10 bar with a significance tick, `supporting_text` quoted, `has_supporting_studies` inline — no external trials DB) · version switcher grouped by KG, latest first, dot-marked when changed, ←/→ keys · "what changed" diff straight out of `$set/$add/$del` · provenance chain from `sources` (`resource_id`/`resource_role`/`upstream_resource_ids`/`source_record_urls`) as infores linkouts · collapsible raw KGX JSON · **Download KGX** (`{"nodes":[…],"edges":[…]}` via `push_event`) · copy-permalink · dark mode · research-use disclaimer · config-driven feedback link. Tailwind 4 + daisyUI, hand-written SVG, no JS chart library.

## Display config (`kgs/`)

`.exs` files that **evaluate to plain data**, read at compile time (`@external_resource` → recompile on change), validated by NimbleOptions (errors name file and key), templates compiled once to token lists — no runtime `eval`. Layering is a deep merge: `_defaults.exs` → `<kg>.exs` → version-scoped blocks selected with `Version.match?` requirements (`"< 2.6.0"`), non-semver falling back to exact match.

```elixir
# kgs/drug-approvals-kg.exs
[
  meta: [display_name: "Drug Approvals KP",
         homepage: "https://github.com/glusman-team/dakp",
         background: "FDA-approved treatment relationships, FAERS-observed uses, …",
         feedback: {:github_issue, repo: "glusman-team/dakp"}],
  prefixes: [DAILYMED: "https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid={id}"],
  vars: [verb: [[when: [predicate: "biolink:treats"], text: "treatment of {object_name}"],
                [when: [predicate: "biolink:applied_to_treat"], text: "reported use in {object_name}"],
                [text: "a relationship with {object_name}"]]],
  sections: [description: ["{subject_name} is linked to {verb}.",
                           "{?clinical_approval_status}Approval status: {clinical_approval_status|humanize}."],
             evidence: ["{FDA_regulatory_approvals|linkout_list}", "{number_of_cases|int} FAERS cases"]],
  fields: [number_of_cases: [label: "Case count", viz: :n],
           clinical_approval_status: [label: "Approval status", viz: :pill]]
]
```

- Grammar: `{field}`, `{field|formatter:arg}`, `{link:label_field,curie_field}`, `{?field}…` (drop the line when absent — this kills the old `NA` noise), `{#field}…{/field}` (list sections). `vars` are ordered rule lists, first match wins, conditions `eq/in/present/absent/gt/lt/match`.
- Formatters are a whitelist in one module: `humanize`, `int`, `sig`, `pct`, `plural`, `date`, `predicate`, `sign_word`, `list`, `linkout`, `linkout_list`, `scinote`.
- `_prefixes.exs` ports the whole `addLinkout` switch (UNII, MONDO, HP, CHEBI, NCBIGene, PMID, PMC, doi, dailymed, …) with the biolink prefix map as fallback; any KG may add or override entries — the extension point for future KGs.
- Field names are **biolink/KGX slots only**. Legacy Perl names (`relationship_strength`, `N_cases`, `Bonferroni_pval`) are mapped to their KGX equivalents, not carried over.
- `mix linkouts.check` validates every config and renders golden pages for the fixtures; it runs in pre-push and CI and is the contributor feedback loop. `linkouts rig --from …RIG.yaml` scaffolds `meta:` from the Resource Ingest Guide Tablassert already emits.
- Six KGs ship: `drug-approvals-kg` (verified against real DAKP output) plus `multiomics-kg`, `wellness-kg`, `microbiome-kg`, `ehr-risk`, `clinical-trials` written from their Perl modules and the Biolink model, exercised by synthetic fixtures. A slot-name mismatch in a real dump is a one-line `.exs` fix.

## Docs (two engines)

- **ExDoc** in `docs/` (tiny mix project, `{:edge_linkouts, path: "../web"}`): `docs/pages/*.md` — quickstart, ingest workflow, "add your KG in 20 lines", config schema, template language, storage format, deployment — plus API docs for the display modules. No Python toolchain in a Go/Elixir repo. [D11]
- **cobra/doc** (`md_docs.go`, `man_docs.go`, `yaml_docs.go`, `rest_docs.go` in v1.10.2): `linkouts docs --out ../docs/cli` writes the CLI reference; committed and verified by a `git diff --exit-code` CI check. `docs.yml` publishes to GitHub Pages.

## Tooling

**Global Nix** (your convention: `home.packages` in SkyeWorkstation's `modules/sgoetz/home.nix`, then `home-manager switch`). No repo flake. [D7] Add: `golangci-lint` 2.14.0, `gofumpt` 0.12.0, `flyctl` 0.4.108, `prek`. Not needed: `clickhouse` (engine is embedded), `elixir`/`erlang` (OTP 28) and `go` 1.26.7 (installed).

**golangci-lint ≠ gofmt/govet.** gofumpt only reformats; `go vet` is a handful of checks. golangci-lint runs ~50 linters in one pass — we enable `govet`, `staticcheck`, `errcheck`, `unused`, `gosimple`, `gocritic`, `gosec`, `misspell`, `revive`, `gofumpt`. It replaces `go vet`. Too slow for pre-commit, so it runs in pre-push + CI.

**prek / `.pre-commit-config.yaml`**, two stages: *pre-commit* (fast, auto-fix) trailing-whitespace, end-of-file-fixer, check-yaml/check-json, gofumpt, `mix format`, gitleaks [D9]; *pre-push* golangci-lint, `go test -race ./...`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `mix linkouts.check`.

**CI** (`ci.yml`, `pull_request` + push to `main`, concurrency group, parallel jobs, no `needs`, every step a `make` target): `go` (gofumpt check, golangci-lint, `test -race`, setup-go cache) · `elixir` (erlef/setup-beam, deps/_build cache keyed on mix.lock; format, credo, warnings-as-errors, test) · `docs` (ExDoc build + generated-markdown diff) · `pre-commit` (all hooks). `deploy.yml` runs `flyctl deploy --remote-only` on `main`, path-filtered to `web/**` and `kgs/**`. [D12]

## Testing — offline, tiny, fast

**Hard rules:** no test touches the network, Cosmos, Fly or Cloudflare; no test reads outside the repo; fixtures only; `make check` under 60 s (CI fails otherwise).

`make fixtures` extracts, once and locally, from the DAKP sample (never committed, never read by CI):

```
cli/testdata/dakp/nodes.ndjson   ~8 nodes (the subjects/objects below)
cli/testdata/dakp/edges.ndjson    6 edges: smallest (868 B), median (~1.1 KB), one with
                                  has_supporting_studies, the 59 KB publications monster,
                                  one contraindicated_in, one treats
cli/testdata/contract/*.json      those edges as encoded docs (full + patched + templated),
                                  written by `linkouts get --raw`
web/test/fixtures/…               the contract docs + a golden render per KG
```

Six edges cover every field shape in the real KG (`sources` nesting, `FDA_regulatory_approvals`, `clinical_approval_status`, `number_of_cases`, `publications`, `supporting_text`, `has_supporting_studies`) in ~70 KB.

**Fakes** (injection at seams, nothing monkey-patched in production code): Go `internal/cosmos` and `internal/engine` are interfaces — an in-memory Cosmos fake with programmable RU charges, 409/412/429s and latency; the chdb backend gets one `//go:build engine` test, skipped by default, so unit tests never load the 117 MB engine. Elixir: `EdgeLinkouts.Cosmos` behaviour with an injected stub (LiveView and codec tests open no socket); the Finch client's HMAC is unit-tested against known-answer vectors from the Cosmos REST docs. The RU limiter takes an injectable clock, so throttle tests don't sleep.

**Suites.** Go: canonicalization and delta table tests, `FuzzDelta` roundtrip (short `-fuzztime` in CI), limiter arithmetic, pipeline end-to-end vs the fake, zero-null assertion after the join. Elixir: StreamData property tests for patch materialization (`decode(encode(x)) == x`), golden HTML per KG, LiveView tests for `/`, `/edges/:uuid`, `?v=` toggling, `/random`, limiter and dedupe tests. **Cross-language contract:** `make fixtures` copies the Go-encoded docs into `web/test/fixtures/`; Elixir must materialize them to the same KGX JSON — this is what stops the two codecs drifting.

## Deployment runbook (README.md) — **Phase 3, not exercised in this pass**

1. `linkouts init` → `linkouts probe` → `linkouts load --nodes … --edges …`
2. `fly launch --name edge-linkouts --region lax --no-deploy` (region `lax`: Azure West US 2 is Quincy WA and Fly retired `sea`; confirm with `fly platform regions`). `fly.toml` carries `app = "edge-linkouts"`, `primary_region = "lax"`.
3. Cloudflare: CNAME `linkouts` → `edge-linkouts.fly.dev`, proxied, SSL Full (strict) so WebSocket upgrades work; then `fly certs add linkouts.skyelanegoetz.com`. `web/config/runtime.exs` gets `PHX_HOST`, `url: [host: "linkouts.skyelanegoetz.com", port: 443, scheme: "https"]`, `check_origin: ["//linkouts.skyelanegoetz.com"]`.
4. `fly secrets set SECRET_KEY_BASE=… COSMOS_ENDPOINT=… COSMOS_DB=edge_linkouts COSMOS_CONTAINER=edges COSMOS_READ_ONLY_KEY=… RU_BUDGET_WEB=450` → `fly deploy` (or push to `main`).
5. **NixOS note:** chdb-go `dlopen`s the extracted `libchdb.so`; if it can't resolve `libstdc++`/`glibc`, set `LD_LIBRARY_PATH=$(nix eval --raw nixpkgs#libstdcxx)/lib:$(nix eval --raw nixpkgs#glibc)/lib` — `.envrc.example` does this. `CHDB_CACHE_DIR` must be writable and private to your user (chdb refuses a world-writable cache dir).

`.envrc` (gitignored; `.envrc.example` committed with these pre-filled): `COSMOS_ENDPOINT`, `COSMOS_DB=edge_linkouts`, `COSMOS_CONTAINER=edges`, `COSMOS_KEY` (rw, CLI only), `COSMOS_READ_ONLY_KEY`, `RU_BUDGET_CLI=450`, `RU_BUDGET_WEB=450`, `CHDB_CACHE_DIR`, `LD_LIBRARY_PATH`, `FLY_APP=edge-linkouts`, `FLY_REGION=lax`, `PHX_HOST=linkouts.skyelanegoetz.com`, `SECRET_KEY_BASE`, `VAULT_KEY`.

## Deviations (audit)

- **[D1]** Reads are limited by an `:atomics` RU token bucket, not Phoenix PubSub. PubSub is a broadcast bus; a limiter needs shared counters. Atomics are lock-free O(1) with no single-process bottleneck.
- **[D2]** Server-side **zstd + trained dictionary**, not browser-side gzip. LiveView renders on the server, so the server decodes anyway; `DecompressionStream("zstd")` exists only in Firefox 138+ (Chrome/Safari: no), so a browser scheme would have forced gzip. Dictionaries are what make ~1 KB JSON compress well, and OTP 28's stdlib `:zstd` (`zstd:dict/2`, `get_dict_id/1`) means no NIF dependency.
- **[D3]** 45% per app (your later number), not "half"; 450 + 450 leaves headroom for the portal and retries. Both budgets are env-tunable.
- **[D4]** Template depth capped at 1 and `$t` must name a *full* version of the same KG. Bounds read cost at one merge and keeps the diff view meaningful; the writer picks the best base automatically.
- **[D5]** In-flight coalescing + 30 s ETS dedupe stops the LiveView double mount from doubling reads. Request dedupe, not an HTTP cache — Cloudflare can't help, the payload is a WebSocket.
- **[D6]** Dropped: KG-scoped random edge, `narrow` search, feedback sliders writing to a local file, `kginfo_logfile`, the external `clinicaltrials.db` lookup (trial data is now inline in `has_supporting_studies`). `/random` returns unscoped.
- **[D7]** No repo `flake.nix`; tooling goes into your global Nix config as you asked.
- **[D8]** Added a committed `.envrc.example` beside the gitignored `.envrc` so variable names are documented.
- **[D9]** Added a `gitleaks` hook, since secrets live in `.envrc`.
- **[D10]** ClickHouse via **chdb-go's embedded engine** only — not `clickhouse-go/v2` (a client for a running server), not a `clickhouse local` subprocess. Cost: ~117 MB module payload + first-run extraction. Benefit: one self-contained Go binary, no CGO, nothing installed.
- **[D11]** ExDoc instead of mkdocs-material: no Python toolchain in a Go/Elixir repo, and the config DSL is Elixir.
- **[D12]** `deploy.yml` deploys on push to `main` (you asked for automatic deploys), path-filtered so CLI-only changes don't redeploy the web app. Written in this pass but dormant — no repo, no push, no deploy until STOP 4.
- **[D15]** A second Cosmos backend, `EdgeLinkouts.Cosmos.FileBackend`, serves `{id,b}` docs from an ndjson file. It exists so the whole app can be run and clicked through locally (`COSMOS_BACKEND=file`) with no cloud calls and no bill, which is what you asked for this pass; production selects the Finch backend by config.
- **[D13]** `/random` is a 3-line controller returning 302, not a LiveView. A LiveView would mount a socket and render just to bounce the browser. It is the only non-LiveView route.
- **[D14]** The Elixir Cosmos client is hand-rolled (~70 LOC on Finch) instead of a community package. The three on hex are `sagan` 0.1.2 (**2017**), `cosmos_db_ex` 0.1.1 (**2021**), `kavaCosmosApiClient` 0.1.0 (**2023**) — all unmaintained, none OTP 28 / built-in-`JSON` aware, each dragging in an old HTTP+JSON stack. Behind a behaviour, so swapping in a maintained client later is a one-file change. The Go side keeps the official, maintained `azcosmos` SDK.

## Build sequence — with STOP points

This pass: **build and verify locally, no deployment, no cloud bill.** All work happens on a new branch `edge-linkouts-monorepo` in this repo — no GitHub repo is created, nothing is pushed, and no `fly`/Cloudflare command is run. `Dockerfile`, `fly.toml`, `ci.yml`, `docs.yml` and `deploy.yml` are written as artifacts and exercised in a later pass.

### Phase 0 — your machine

- [ ] **0.1** I write the diff adding `golangci-lint`, `gofumpt`, `flyctl`, `prek` to `home.packages` in SkyeWorkstation's `modules/sgoetz/home.nix`. (`flyctl` isn't needed until Phase 3; it rides along so you rebuild once, not twice.)
- [ ] ⛔ **STOP 1 — you run `home-manager switch` (or `nixos-rebuild switch`) and tell me it landed.** Nothing after this point builds: the pre-commit hooks and every `make` target shell out to those four binaries.

### Phase 1 — scaffold, then secrets

- [ ] **1.1** Branch `edge-linkouts-monorepo`; repo layout, `Makefile`, `.gitignore`, `.pre-commit-config.yaml`, workflow files (written, not run), README skeleton.
- [ ] **1.2** Write `.envrc.example`, copy it to `.envrc` (gitignored), `prek install --hook-type pre-commit --hook-type pre-push`.
- [ ] ⛔ **STOP 2 — `.envrc` now exists; fill it in.** Needed for anything that talks to Cosmos:
  - `COSMOS_ENDPOINT`, `COSMOS_KEY` (primary, CLI), `COSMOS_READ_ONLY_KEY` (web) — Portal → your Cosmos account → **Settings → Keys**, or `az cosmosdb keys list --name <acct> --resource-group <rg> --type keys`. Your ARM template has `"disableLocalAuth": false`, so keys are enabled.
  - `SECRET_KEY_BASE` (`mix phx.gen.secret`), `VAULT_KEY` (`openssl rand -hex 32`).
  - Everything else is pre-filled. **If you skip this, Phase 2 still completes** — the whole build runs against fakes and the local file backend; only the optional smoke test (2.9) is skipped.
- [ ] **1.3** I do the one-time downloads myself: `mix local.hex --force`, `mix local.rebar --force`, `go mod download` (includes the ~117 MB chdb engine module, extracted to `CHDB_CACHE_DIR` on first run), the `esbuild`/`tailwind` binaries, and the `heroicons`/`daisyui` source deps.

### Phase 2 — build, then verify locally (no cloud)

- [ ] **2.1** `make fixtures`: extract 6 edges / 8 nodes + contract docs from the DAKP sample (the 134 MB file is never committed).
- [ ] **2.2** `cli`: cobra root, `internal/config`, `internal/cosmos` (interface + azcosmos impl + in-memory fake + provision), `init`, `probe`.
- [ ] **2.3** `cli/internal/engine`: embedded chdb session (`max_threads` = NumCPU), `join.sql`, streaming, zero-null test.
- [ ] **2.4** `cli/internal/codec`: canonical JSON, `BuildDict`, blob encode/decode, delta encode/apply, fuzz roundtrip, contract fixtures.
- [ ] **2.5** `cli/internal/ratelimit` + `pipeline`: fan-in, charge reconciliation, create-first/409-merge, repack vs `--no-repack`, reservoir sampling, progress/ETA, `--dry-run`/`--out`; then `get`, `rig`, `docs`.
- [ ] **2.6** `web`: minimal `phx.new` + the dep deletions, built-in `JSON`, Cosmos behaviour + Finch/HMAC client + **file backend** + fake, atomics limiter, dedupe, codec + cross-language contract test.
- [ ] **2.7** `kgs/` + display engine: schema, loader, template compiler, formatters, `_prefixes.exs`, `mix linkouts.check`; port the six KGs (drug approvals first, from the fixtures).
- [ ] **2.8** UI: EdgeLive / HomeLive / `/random`, SVG diagram, evidence panel, version switcher + diff, KGX download, dark mode, a11y. Delete `KGinfo.pl`, `KGindexQuery.py`, `KGinfo/`. ExDoc project + guides + generated CLI reference.
- [ ] **2.9** ⛔ **STOP 3 — optional real-account smoke test; I ask before touching Cosmos.** If `.envrc` has keys and you say go: `linkouts init` → `linkouts probe --n 20` → load the 6 fixture edges as two versions → open them in a locally running `mix phx.server` using the read-only key. Roughly 50 RU against the free tier, so no cost — but it is a real write to your account, so it waits for your yes.

### Phase 3 — deployment (later pass, on your signal)

- [ ] ⛔ **STOP 4 — when you want to deploy:** `fly auth login`; `fly tokens create deploy -x 90d` → repo secret `FLY_API_TOKEN`; create the GitHub repo, enable Actions, set the Pages source to "GitHub Actions"; then I push the branch and wire `deploy.yml`. Until then `fly.toml`/`Dockerfile`/`deploy.yml` sit unused.
- [ ] ⛔ **STOP 5 — Cloudflare, once the app is on Fly:** CNAME `linkouts` → `edge-linkouts.fly.dev` (proxied, SSL Full/strict so WebSocket upgrades work), then `fly certs add linkouts.skyelanegoetz.com`. I can't create DNS records or issue certs from here.

## Verification (this pass — all local, zero cloud spend)

- `make check` = gofumpt, golangci-lint, `go test -race`, mix format, credo, warnings-as-errors, `mix test`, `mix linkouts.check`, docs build — **offline, under 60 s**
- `linkouts load --dry-run --out /tmp/edges.ndjson` on the DAKP sample: zero nulls, compression ratio, byte savings from templating, ETA — writes a local file, touches nothing
- **Local end-to-end (the "monkeypatched" deployment):** `COSMOS_BACKEND=file COSMOS_DOCS=/tmp/edges.ndjson mix phx.server` → click through `/`, `/edges/<uuid>`, `?v=` version toggle, the diff view, `/random` → 302, Download KGX, dark mode. Same code path as production with the Finch client swapped for the file backend.
- Cross-language contract: the Go-encoded docs materialize to identical KGX JSON in Elixir
- LiveView tests with the injected Cosmos stub: mount, version switch, throttle state, 404

**Deferred to Phase 3:** `linkouts probe` RU numbers against the real account, portal metrics confirming ≤ 450 RU/s under load, `fly deploy` behind `https://linkouts.skyelanegoetz.com` (LiveView socket connects, TLS valid).
