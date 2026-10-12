# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary: Translator consortium researchers and curators. They arrive with an edge UUID (or via a random/KG entry point) to check what a knowledge-graph edge asserts, what evidence backs it, where it came from, and how it changed across KG releases.

Secondary audiences (data consumers, reviewers, data-ops users): undecided; the `linkouts` CLI's load/probe/status/purge surface exists for whoever runs ingest, but no distinct reader persona is confirmed.

## Product Purpose

linkouts turns raw knowledge-graph edges (KGX `edges.ndjson` + `nodes.ndjson` releases) into permanent, human-readable pages: one URL per edge showing the assertion, its evidence and provenance, and a per-release diff of how the edge changed. Success means a curator can answer "what does this edge claim and why should I believe it" from the page alone, for every release of every supported KG, at near-zero read cost.

## Positioning

A neighboring tool could copy the page layout but not the mechanism: each edge's full version history lives in a single zstd blob (trained-dictionary compression) fetched by one point read against a Cosmos container with indexing mode `none`, with all naming, ordering, and layout derived server-side in Phoenix. Storage holds raw facts only; nothing is precomputed, indexed, or queried. Adding a KG is a declarative `.exs` display config in `kgs/`, not code.

## Operating Context

- Data arrives as KGX releases produced by Tablassert; `--kg`/`--version` are inferred from its filenames, with the canonical `infores:` form (`infores:drugapprovals-kp-1.23.3`) accepted on load and the prefix-less slug (`drugapprovals-kp`) stored on documents and used in URLs.
- Live at https://linkouts.skyelanegoetz.com behind Cloudflare (origin lockdown via `X-Origin-Key`) on Fly.io; deploys on every push to `main` touching `web/`, `kgs/`, `Dockerfile`, or `fly.toml`.
- Entry points: `/` (KG list with release pills), `/edges/:uuid` (edge page with per-release toggle and diff), `/random`, `/<kg>/random`, `/<kg>/random?version=<label>`.
- Read path never queries Cosmos: point reads by id, coalesced and cached, under a strict `RU_BUDGET_WEB` so traffic cannot starve ingestion (`RU_BUDGET_CLI` caps writes).
- Dev workflow is `make` targets (`make setup`, `make check`, `make local-load`, `make local-web`); secrets come from direnv, never the repo.

## Capabilities and Constraints

- Web: Phoenix LiveView app in `web/`; per-KG display behavior driven by `kgs/*.exs` (`_default.exs` fallback); no database queries, no indexed reads.
- CLI (`cli/`, Go + embedded ClickHouse/chDB): init, probe, status, load, purge; rate-limited writes.
- Terminology is fixed by the domain: `infores:` canonical names, KG slugs, KGX node/edge records, RU budgeting.
- Undecided: secondary reader personas; whether random/discovery surfaces grow beyond curation use.

## Brand Commitments

- Name: linkouts (live domain linkouts.skyelanegoetz.com).
- Must read as vaguely associated with ISB/Translator.
- Do NOT use official Translator assets (logo, brand kit) — explicit user constraint, "yet" implies this may change but is not authorized now.
- No other voice, palette, or identity constraints are binding; visual world is open for later design work.

## Evidence on Hand

- Live deployment serving `infores:drugapprovals-kp` releases 1.23.3 and 1.23.4.
- DAKP sample data for local load (`make local-load`).
- `docs/pages/` (quickstart, add-a-kg, config-reference, storage-format, deployment runbook) and `docs/adr/` record real architecture decisions; `PLAN.md` and `plans/kg-quickbar-scoped-random.md` record build history.
- No testimonials, marketing claims, or benchmarks exist; future work must not fabricate them.

## Product Principles

1. Evidence and citation accuracy outrank presentation: a page that misstates an assertion or its provenance is a defect, whatever it looks like.
2. Every release of an edge stays inspectable: version history and the cross-release diff are the product, not a feature of it.
3. Cost discipline is a feature: minimal storage, point reads only, hard RU budgets are part of the design contract, not implementation detail.
4. Adding a KG is data, not code: new graphs ship as declarative `kgs/*.exs` configs.

## Accessibility & Inclusion

No product-specific accessibility standard has been established (open decision; default web good practice applies until the user sets one).
