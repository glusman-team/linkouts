# Single source of truth for every check. CI jobs and prek hooks call these targets,
# so a green `make check` locally means a green CI run.
#
# Everything here is OFFLINE: no target talks to Cosmos, Fly or Cloudflare except the
# explicitly named `smoke-*` targets, which are never run by CI or hooks.

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

CLI  := cli
WEB  := web
DOCS := docs
BIN  := $(CLI)/bin/linkouts

# Source for `make fixtures` / `make local-load` only: never committed, never read by CI.
# Fixtures come from DAKP >= 1.0.0 only (1.11.2 and 1.16.0). The pre-1.0.0 samples
# (e.g. Tablassert's agent_0.0.1.*) are deliberately NOT used.
DAKP_DIR ?= $(HOME)/Desktop/dakp-latest
DAKP_OLD ?= 1.11.2
DAKP_NEW ?= 1.16.0
DAKP_EDGES ?= $(DAKP_DIR)/$(DAKP_OLD)/drug_approvals_kg_edges_v$(DAKP_OLD).ndjson
DAKP_NODES ?= $(DAKP_DIR)/$(DAKP_OLD)/drug_approvals_kg_nodes_v$(DAKP_OLD).ndjson

# Hard ceiling for the whole offline gate (seconds); see PLAN.md "Testing".
CHECK_BUDGET ?= 60

.PHONY: help
help: ## List targets
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_.-]+:.*## /{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

# ---------------------------------------------------------------- setup

.PHONY: setup
setup: ## One-time local deps (hex, rebar, go modules, mix deps, asset binaries)
	mix local.hex --force --if-missing
	mix local.rebar --force --if-missing
	cd $(CLI) && go mod download
	cd $(WEB) && mix deps.get && mix assets.setup
	cd $(DOCS) && mix deps.get

.PHONY: hooks
hooks: ## Install prek hooks (pre-commit + pre-push)
	prek install --hook-type pre-commit --hook-type pre-push

# ---------------------------------------------------------------- go

.PHONY: build
build: ## Build the linkouts CLI into cli/bin/
	cd $(CLI) && CGO_ENABLED=0 go build -trimpath -o bin/linkouts ./cmd/linkouts

.PHONY: go-fmt go-fmt-check go-lint go-test go-fuzz
go-fmt: ## gofumpt -w
	cd $(CLI) && gofumpt -w .

go-fmt-check: ## gofumpt diff check
	@cd $(CLI) && out="$$(gofumpt -l .)"; if [ -n "$$out" ]; then echo "gofumpt needed:"; echo "$$out"; exit 1; fi

go-lint: ## golangci-lint (govet, staticcheck, errcheck, gosec, ...)
	cd $(CLI) && golangci-lint run ./...

go-test: ## go test -race (unit tests only; engine tests need -tags engine)
	cd $(CLI) && go test -race -count=1 ./...

go-test-engine: ## go test against the embedded chdb engine (downloads ~117 MB once)
	cd $(CLI) && go test -race -count=1 -tags engine ./internal/engine/...

go-fuzz: ## Long local fuzz run of the delta codec
	cd $(CLI) && go test -run=^$$ -fuzz=FuzzDelta -fuzztime=2m ./internal/codec/

# ---------------------------------------------------------------- elixir

.PHONY: ex-fmt ex-fmt-check ex-lint ex-compile ex-test kgs-check
ex-fmt: ## mix format
	cd $(WEB) && mix format

ex-fmt-check: ## mix format --check-formatted
	cd $(WEB) && mix format --check-formatted

ex-compile: ## Compile with warnings as errors
	cd $(WEB) && mix compile --warnings-as-errors --force

ex-lint: ## credo --strict
	cd $(WEB) && mix credo --strict

ex-test: ## mix test (Cosmos stubbed, no network)
	cd $(WEB) && mix test --warnings-as-errors

kgs-check: ## Validate every kgs/*.exs and render the golden fixtures
	cd $(WEB) && mix linkouts.check

# ---------------------------------------------------------------- docs

.PHONY: cli-docs docs docs-check
cli-docs: build ## Regenerate docs/cli/*.md from the cobra command tree
	$(BIN) docs --out $(DOCS)/cli

docs: cli-docs ## Build the ExDoc site into docs/doc/
	cd $(DOCS) && mix docs --warnings-as-errors

docs-check: cli-docs ## Fail if generated CLI docs are stale, then build the site
	git diff --exit-code -- $(DOCS)/cli
	cd $(DOCS) && mix docs --warnings-as-errors

# ---------------------------------------------------------------- fixtures

.PHONY: fixtures
fixtures: build ## Re-extract test fixtures from the local DAKP sample (one-time, local)
	DAKP_DIR="$(DAKP_DIR)" DAKP_OLD="$(DAKP_OLD)" DAKP_NEW="$(DAKP_NEW)" python3 scripts/extract_fixtures.py
	$(BIN) load --nodes $(CLI)/testdata/dakp/nodes.ndjson --edges $(CLI)/testdata/dakp/edges.ndjson \
	  --key drug-approvals-kg-1.11.2 --store file:$(CLI)/testdata/contract/docs.ndjson
	$(BIN) load --nodes $(CLI)/testdata/dakp/nodes.ndjson --edges $(CLI)/testdata/dakp/edges.v2.ndjson \
	  --key drug-approvals-kg-1.12.0 --store file:$(CLI)/testdata/contract/docs.ndjson
	cp $(CLI)/testdata/contract/docs.ndjson $(CLI)/testdata/contract/docs.golden.ndjson
	mkdir -p $(WEB)/test/fixtures/contract
	cp $(CLI)/testdata/contract/*.ndjson $(WEB)/test/fixtures/contract/
	cd $(WEB) && mix test test/contract_test.exs

# ---------------------------------------------------------------- gates

.PHONY: fmt fmt-check lint test check precommit
fmt: go-fmt ex-fmt ## Format everything

fmt-check: go-fmt-check ex-fmt-check ## Format checks only

lint: go-lint ex-lint ## All linters

test: go-test ex-test kgs-check ## All offline tests

check: ## Full offline gate (mirrors CI), fails past CHECK_BUDGET seconds
	@start=$$(date +%s); \
	$(MAKE) --no-print-directory fmt-check lint ex-compile test; \
	elapsed=$$(( $$(date +%s) - start )); \
	echo "make check: $${elapsed}s (budget $(CHECK_BUDGET)s)"; \
	if [ $$elapsed -gt $(CHECK_BUDGET) ]; then echo "over budget"; exit 1; fi

precommit: ## Run every prek hook over the whole tree
	prek run --all-files

# ---------------------------------------------------------------- local run (no cloud)

LOCAL_DOCS ?= $(CURDIR)/tmp/edges.local.ndjson

.PHONY: local-load local-web
local-load: build ## Encode the DAKP sample to a local docs file (no Cosmos, no RU)
	mkdir -p tmp
	$(BIN) load --nodes "$(DAKP_NODES)" --edges "$(DAKP_EDGES)" --store file:$(LOCAL_DOCS)

local-web: ## Run Phoenix against the local docs file (file backend, no Cosmos)
	cd $(WEB) && COSMOS_BACKEND=file COSMOS_DOCS=$(LOCAL_DOCS) iex -S mix phx.server

# ---------------------------------------------------------------- real account (manual only)

.PHONY: smoke-init smoke-probe
smoke-init: build ## [CLOUD] Create db/container on the real account
	$(BIN) init

smoke-probe: build ## [CLOUD] Measure RU per op with 20 throwaway docs
	$(BIN) probe --n 20

# ---------------------------------------------------------------- housekeeping

.PHONY: clean
clean: ## Remove build outputs
	rm -rf $(CLI)/bin $(WEB)/_build $(DOCS)/_build $(DOCS)/doc tmp
