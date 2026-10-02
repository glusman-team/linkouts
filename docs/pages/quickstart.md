# Quickstart

Everything here runs offline against the fixtures committed in the repository. Nothing touches
Azure.

## Prerequisites

Go, Elixir/OTP 28 and `make`. On NixOS these come from the dev shell. The CLI is built with
`CGO_ENABLED=0`: the embedded ClickHouse engine is loaded at runtime, not linked.

## 1. Build and test

```sh
make check
```

`make check` is what CI runs: formatting, lint, the Go tests with `-race`, the Elixir tests, and
the cross-language contract test. It never needs network access or credentials. If it is green
locally, CI is green.

## 2. Load the fixtures into a local file store

The CLI can store to a file instead of Cosmos, which is what the contract fixtures are made from:

```sh
cli/bin/linkouts load drug-approvals-kg-1.11.2 \
  --nodes cli/testdata/dakp/nodes.ndjson \
  --edges cli/testdata/dakp/edges.ndjson \
  --store file:/tmp/edges.ndjson

cli/bin/linkouts load drug-approvals-kg-1.16.0 \
  --nodes cli/testdata/dakp/nodes.ndjson \
  --edges cli/testdata/dakp/edges.v2.ndjson \
  --store file:/tmp/edges.ndjson
```

The second load merges into the same documents. Each edge now holds both versions, the newer one
stored as a delta against the older.

## 3. Read one back

```sh
cli/bin/linkouts get 12ae7437-12dc-3c2a-b487-5297c09fc5e5 --store file:/tmp/edges.ndjson --list
```

`--list` shows each stored version and whether it is full or a delta, and against what.

## 4. Serve it

Point the web app at the same file and start it:

```sh
cd web
COSMOS_DOCS=/tmp/edges.ndjson mix phx.server
```

In dev, the app uses this file backend unless Cosmos credentials are present in the environment
(or `COSMOS_BACKEND=http` forces Cosmos). With neither set it starts against an empty store, and
every edge page is a 404.

Then open `http://localhost:4000/edges/12ae7437-12dc-3c2a-b487-5297c09fc5e5`, or
`http://localhost:4000/random`.
