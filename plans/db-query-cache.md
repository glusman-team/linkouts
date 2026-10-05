# Nebulex-backed cache for Cosmos reads + RU budget rebalance (web 15%, CLI 75%)

Status: EXECUTED (2026-10-05). `make check` green in 21 s (budget 60 s), 161 web tests
0 failures, docs site builds with `--warnings-as-errors`, runtime smoke against the file
backend confirms cache hits, `RU_BUDGET_WEB=150` and `POOL_TTL_MS` wiring. Two execution
notes that differ from the text below: (1) named Nebulex instances are addressed with
`with_dynamic_cache/2` — the leading-instance-arg call forms collide with the public
default arities and would silently hit the default cache; (2) misses are detected with
`fetch/1`, never `get/1` (`get` returns `{:ok, default}` on a miss, which would replay as
a cached nil). `docs-check`'s `git diff --exit-code -- docs/cli` can only pass once the
working tree is committed.

## Context

The DB read path has exactly one cache today: the recent-results table bolted into
`EdgeLinkouts.Dedupe` (`web/lib/edge_linkouts/dedupe.ex`), beside its in-flight
coalescing. It works, but it is ~150 lines of hand-rolled TTL/sweep/room logic with no
eviction (a full table silently stops storing), no hit/miss counters, and no way to see
whether it is earning its keep. The read funnel (`EdgeLinkoutsWeb.Edges`) also just grew
a second TTL class — the working tree (mid-flight quickbar work) added
`fetch_pool_index/0`, `fetch_pool/2` at a 15 min TTL through the same table.

Decision (user, 2026-10-05): adopt **Nebulex** as the cache layer instead of growing the
hand-rolled ETS further. Mnesia was considered and rejected: the app never writes, Fly
disk is ephemeral (`web/fly.toml` does not exist yet, no volume), so `disk_copies` buys
nothing and `ram_copies` is ETS with a transaction layer and a schema dir on top.

Second decision in the same pass: rebalance the RU budget. The web app's slice of the
1000 RU/s free tier drops to **15% (150 RU/s)**; the Go ingestion CLI takes **75%
(750)**; 10% stays headroom for the portal and retries. Supersedes `PLAN.md [D3]`
(45/45); PLAN.md is a pass-1 record and is left as written.

What Nebulex does **not** replace: single-flight coalescing. `fetch_or_store/3` and
`get_or_store/3` are explicitly non-atomic in Nebulex v3 (the default
`Nebulex.Adapter.CompositeKV` implementation), so N concurrent misses run the function N
times. `Dedupe` keeps the claims/waiters/monitor machinery; only the result store swaps.

## Approach

### Cache layer (Nebulex local adapter)

- Two new deps, both pure Elixir, no NIF, MIT: `{:nebulex, "~> 3.0"}` (3.0.4) and
  `{:nebulex_local, "~> 3.0"}` (3.0.0). Their only hard dependency beyond each other is
  `nimble_options`, already a project dep. The optional `decorator`, `shards`, `ex2ms`
  and `telemetry` packages are **not** added: no decorators, default `:ets` backend, and
  stats are read through the Info API, not telemetry events.
- New module `EdgeLinkouts.Cache`: `use Nebulex.Cache, otp_app: :edge_linkouts,
  adapter: Nebulex.Adapters.Local`. Started in `application.ex` before `Dedupe`.
- `Dedupe` swaps its internals, keeps its API. `recent/2` becomes `Cache.get/2`;
  `remember/4` becomes `Cache.put/3` with the per-read `:ttl_ms` override it just
  gained (`execute/4` is untouched from the in-flight work); `clear/1` becomes
  `Cache.delete_all/1`. The `:max_entries` table bound, `room?/1` and `sweep/1` are
  deleted — Nebulex owns bounding now.
- Failure rule preserved exactly: only `{:ok, _}` is stored. A 404, a
  `{:throttled, ms}` or `:budget_exhausted` is retried, never replayed. The
  server-wide kill switch (`dedupe_ttl_ms: 0` in `config/test.exs`, "a caller's
  override cannot revive it", added in the in-flight work) stays as a guard around the
  put.
- Cache contents follow the read funnel, per the "stored doc only" decision applied to
  edges: edge reads store the stored document `%{"id","b","d"}`; the pool reads store
  what `Edges.read/3` already returns (the decoded index / decoded pool) — same as the
  in-flight code and `plans/kg-quickbar-scoped-random.md` ("decoded pools, so decoding
  happens once per node per TTL"). No second decoded-blob layer for edge pages.

### Eviction (the "LRU or whatever you recommend" decision)

The local adapter's **generational GC** is the recommendation — no extra adapter. Reads
promote entries from the old generation into the new one, so hot keys survive; each
`gc_interval` tick drops the oldest generation wholesale; size/memory health checks run
every `gc_memory_check_interval` and trigger GC when `max_size` or `allocated_memory`
is exceeded; TTL-expired entries are also purged at GC time. Config:

```elixir
config :edge_linkouts, EdgeLinkouts.Cache,
  gc_interval: :timer.minutes(15),      # generation length == longest TTL class
  max_size: 10_000,                     # same entry bound as the old max_entries
  allocated_memory: 64 * 1024 * 1024,   # revisit when a real Fly machine size exists
  gc_memory_check_interval: :timer.seconds(10)
```

This deletes the "never evicts early" guarantee (a full table used to refuse to store).
That guarantee is a silent hit-rate cliff; eviction is the normal trade. Accepted by the
user. `gc_cleanup_delay` (default 10 s) keeps in-flight reads safe across generation
swaps, and the adapter retries table-access races internally.

### Budget rebalance

| knob | old | new | where |
|---|---|---|---|
| `ru_budget_web` / `RU_BUDGET_WEB` | 450 | **150** | `config.exs`, `runtime.exs`, `RateLimiter` default + moduledoc, `probe.go` docstring |
| `RU_BUDGET_CLI` / `DefaultRUps` | 450 | **750** | `.envrc.example`, README table, `cli/internal/config/config.go`, `root.go` flag help |
| headroom | 100 | 100 (10%) | unchanged |

The pre-call gate stays as is: `allow?/2` checks `spent + estimate <= budget` with
`cosmos_estimated_read_ru: 10`, `charge/2` debits the real `x-ms-request-charge`
afterward — no estimate is ever pre-debited, so at 150 the gate starts refusing only
when actual spend nears 150 RU in the 1 s window.

Crawler defence: no negative caching (404s stay uncached, retried every time). The
mitigation is a Cloudflare rate-limiting rule on `linkouts.skyelanegoetz.com` — manual,
STOP-5 territory, noted in the deployment doc, not automated here.

## Files to modify

Web:
- `web/mix.exs` — add the two deps with a justifying comment next to the Finch one.
- `web/lib/edge_linkouts/cache.ex` — **new**, the `use Nebulex.Cache` wrapper + moduledoc
  (TTL classes, generational eviction, why coalescing is not here).
- `web/lib/edge_linkouts/application.ex` — start `EdgeLinkouts.Cache` before `Dedupe`.
- `web/lib/edge_linkouts/dedupe.ex` — swap ETS store for `Cache.get/put/delete_all`;
  delete table init, `room?/1`, `sweep/1`, `@default_max_entries`; keep `execute/4`,
  claims/waiters, `clear/1`, the ttl-zero kill switch; rewrite moduledoc.
- `web/lib/edge_linkouts/rate_limiter.ex` — `@default_budget 150`, moduledoc text.
- `web/config/config.exs` — `ru_budget_web: 150`; `config :edge_linkouts, EdgeLinkouts.Cache, ...`.
- `web/config/runtime.exs` — `RU_BUDGET_WEB` default `"150"`; wire `DEDUPE_TTL_MS` and
  `POOL_TTL_MS` (moves the `@pool_ttl_ms` module attribute in `edges.ex` into config
  `:pool_ttl_ms`, read via `Application.get_env`, so both TTL classes are env-tunable).
- `web/config/test.exs` — `dedupe_ttl_ms: 0` comment now says "cache"; nothing else
  (the shared instance's 15 min `gc_interval` is harmless: tests rely on
  expired-on-read, and cache tests start their own instances).
- `web/lib/edge_linkouts_web/edges.ex` — replace the `@pool_ttl_ms` attribute with the
  config lookup; no other change.
- `web/test/edge_linkouts/dedupe_test.exs` — coalescing tests unchanged; "recent
  results" block rewritten for get/put semantics; "a full table stops remembering
  instead of evicting" replaced by an eviction test.
- `web/test/edge_linkouts/cache_test.exs` — **new**: start own instances with fast
  `gc_interval`/`max_size`/`gc_memory_check_interval`, assert generation eviction,
  expired-on-read, `info!(:stats)` hit/miss counters.

CLI + docs:
- `cli/internal/config/config.go` — `DefaultRUps = 750.0`.
- `cli/cmd/linkouts/root.go` — flag help "default $RU_BUDGET_CLI or 750".
- `cli/cmd/linkouts/probe.go` — "the web app is budgeted at 150".
- `docs/cli/*.md` — regenerate via `make cli-docs` (help text changed; `docs-check` enforces).
- `README.md` — config table row: defaults CLI 750 / web 150; add `DEDUPE_TTL_MS`, `POOL_TTL_MS`.
- `.envrc.example` — budgets + new TTL vars; fix the "45% per app" comment.
- `docs/pages/deployment.md` — budget prose, `fly secrets` example `RU_BUDGET_WEB=150`,
  Cloudflare rate-limit note for crawlers.
- `docs/mix.exs` — add `EdgeLinkouts.Cache` to `filter_modules` and the "Read path"
  group (Dedupe's moduledoc will reference it; omitting it dangles the reference).

## Reuse

- `Dedupe.execute/4` per-read `:ttl_ms` override — just landed in the working tree; kept verbatim.
- `Edges.read/3` funnel and its collapse of `:budget_exhausted` / `{:throttled, _}` to
  `{:error, :rate_limited}` — untouched.
- The `Cosmos.Fake` test pattern (`set_latency`, `queue_error`, `calls`) that the
  coalescing tests build on.
- `RateLimiter.stats/1` as the house pattern for "callable observability, no dashboard".
- `config/test.exs`'s `dedupe_ttl_ms: 0` kill switch and the test-isolation rationale
  (`web/config/test.exs:29-31`).
- `Dedupe.clear/1` as the operator knob after a `linkouts load` (now `delete_all`).

## Steps

1. **Precondition:** the in-flight quickbar work (60 modified files, including
   `dedupe.ex` and `edges.ex`) is committed. Re-read `edges.ex` and `dedupe.ex` before
   editing — this plan was written against that moving state.
2. `mix.exs` deps; create `EdgeLinkouts.Cache`; add to `application.ex`; base config in
   `config.exs`. `mix deps.get && mix compile --warnings-as-errors`.
3. Swap `Dedupe` internals (get/put/delete_all, kill-switch guard, delete table code).
4. Tests: rewrite the "recent results" block; new `cache_test.exs` (eviction, expiry,
   stats). Keep `dedupe_ttl_ms: 0` semantics tested (override cannot revive).
5. Budget rebalance across the web config and the Go CLI; regenerate `docs/cli`.
6. TTL env wiring: `:pool_ttl_ms` config + `runtime.exs` (`DEDUPE_TTL_MS`, `POOL_TTL_MS`).
7. Docs: README, `.envrc.example`, `deployment.md`, `docs/mix.exs` module filter.
8. Full gate: `make check` (60 s budget holds — no new slow tests) and `cd web && mix precommit`.

## Verification

- `cd web && mix test` — all coalescing tests green unchanged; cache tests green:
  double-mount costs one read, failures never replayed, TTL expiry, eviction replaces
  the old refuse-to-store test, `info!(:stats)` counts hits and misses.
- `mix credo --strict`, `mix format --check-formatted`, `mix compile --warnings-as-errors`.
- `make check` still under its 60 s budget.
- Manual: `make local-load && make local-web`, open an edge page twice (one backend read),
  `iex> EdgeLinkouts.Cache.info!(:stats)` shows `hits: 1`; `Dedupe.clear()` then reload
  re-reads. `/random` twice within 15 min: pool read once.
- Budget: `iex> EdgeLinkouts.RateLimiter.stats()` reports `remaining: 150` on a fresh
  window; `cli/bin/linkouts load --help` shows the 750 default; `make cli-docs &&
  git diff --exit-code -- docs/cli` is clean.
- Real-account (manual, later): `linkouts probe --n 20` before/after a page-load burst —
  web reads stay well under 150 RU/s.

## Notes / assumptions

- Supersedes `PLAN.md [D3]` (45/45) and the "6 runtime deps" line (`PLAN.md:113`): the
  count becomes 8 runtime deps, zero new NIFs. PLAN.md itself is a pass-1 record and is
  not edited; this file is the decision record.
- `fetch_or_store/3` is deliberately not used (non-atomic in v3); the put happens inside
  the coalesced fun, so waiters get the result by message exactly as today and the
  post-return connected mount hits the cache.
- Expired entries are evicted lazily (on read) or at GC ticks; a TTL-expired entry can
  occupy memory up to one generation. That is bounded by `max_size`/`allocated_memory`
  and costs nothing at read time.
- `allocated_memory: 64 MiB` is a starting guess for a dev-sized machine; revisit when
  the Fly machine size is chosen (`fly.toml` does not exist yet).
- Pool/index entries hold decoded maps (small: ~1 KB index, ~1-4 KB per pool), so
  entry-count, not bytes, is the binding constraint at current sizes.
- Cloudflare rate-limiting rule for crawlers is a manual follow-up at STOP 5; this repo
  never runs cloud commands.
