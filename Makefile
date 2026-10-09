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

# The canonical KG name, in the infores form the wiki lists it as. A load key is $(KG)-$(VERSION);
# the slug stored on each document ("k") and used in URLs and pool ids is the same name without
# the infores: prefix. Changing the KG here is the only place its name is spelled out.
KG ?= infores:drugapprovals-kp

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

go-test: ## go test -race over every package, including the embedded engine
	cd $(CLI) && go test -race -count=1 ./...

go-test-fast: ## go test -short: skips the embedded ClickHouse tests (~540 MiB extraction)
	cd $(CLI) && go test -short -count=1 ./...

go-fuzz: ## Long local fuzz run of the delta codec
	cd $(CLI) && go test -run=^$$ -fuzz=FuzzDeltaRoundTrip -fuzztime=2m ./internal/codec/
	cd $(CLI) && go test -run=^$$ -fuzz=FuzzBlobRoundTrip -fuzztime=1m ./internal/codec/

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

ex-test-cluster: ## two-node cluster proofs (starts distribution on loopback)
	cd $(WEB) && mix test --warnings-as-errors --include cluster --only cluster

kgs-check: ## Validate every kgs/*.exs and render the golden fixtures
	cd $(WEB) && mix linkouts.check

# ---------------------------------------------------------------- docs

.PHONY: cli-docs docs docs-check
cli-docs: build ## Regenerate docs/cli/*.md from the cobra command tree
	$(BIN) docs --out $(DOCS)/cli

docs: cli-docs ## Build the ExDoc site into docs/doc/
	cd $(DOCS) && mix docs --warnings-as-errors

# git diff alone misses a page for a brand-new command, because the file is untracked rather than
# modified; the ls-files check catches that case.
docs-check: cli-docs ## Fail if generated CLI docs are stale, then build the site
	git diff --exit-code -- $(DOCS)/cli
	@untracked="$$(git ls-files --others --exclude-standard -- $(DOCS)/cli)"; \
	  if [ -n "$$untracked" ]; then echo "uncommitted generated CLI docs: $$untracked"; exit 1; fi
	cd $(DOCS) && mix docs --warnings-as-errors

# ---------------------------------------------------------------- fixtures

# Contract fixtures are generated with the pure-Go engine and no dictionary on purpose: they
# must be reproducible on any machine without extracting the ~540 MiB ClickHouse payload, and
# the Elixir contract test must be able to decode them with nothing but :zstd and JSON.
# Two versions of the same six edges, so the delta path is exercised, not just the full path.
FIXTURE_ENGINE := fake
FIXTURE_STORE  := file:$(CLI)/testdata/contract/docs.ndjson
# A fixed reservoir seed and pool timestamp, so regenerating the fixtures gives identical bytes and
# a diff against the committed copy means something changed, not that the clock moved.
FIXTURE_REPRO  := --sample-seed 1 --sampled-at 2026-01-01T00:00:00Z
FIXTURE_NODES  := $(CLI)/testdata/dakp/nodes.ndjson

.PHONY: fixtures contract
fixtures: build ## Re-extract test fixtures from the local DAKP sample (one-time, local)
	DAKP_DIR="$(DAKP_DIR)" DAKP_OLD="$(DAKP_OLD)" DAKP_NEW="$(DAKP_NEW)" python3 scripts/extract_fixtures.py
	rm -f $(CLI)/testdata/contract/docs.ndjson $(CLI)/testdata/contract/docs.golden.ndjson
	$(MAKE) --no-print-directory contract

contract: build ## Regenerate the committed contract fixtures and their golden copy
	mkdir -p $(CLI)/testdata/contract
	rm -f $(CLI)/testdata/contract/docs.ndjson $(CLI)/testdata/contract/drift.ndjson \
	  $(CLI)/testdata/contract/unresolvable.ndjson $(CLI)/testdata/contract/dictdocs.ndjson \
	  $(CLI)/testdata/contract/fixture.dict
	$(BIN) load $(KG)-1.11.2 --nodes $(FIXTURE_NODES) \
	  --edges $(CLI)/testdata/dakp/edges.ndjson --engine $(FIXTURE_ENGINE) \
	  --store $(FIXTURE_STORE) --progress=false $(FIXTURE_REPRO)
	$(BIN) load $(KG)-1.16.0 --nodes $(FIXTURE_NODES) \
	  --edges $(CLI)/testdata/dakp/edges.v2.ndjson --engine $(FIXTURE_ENGINE) \
	  --store $(FIXTURE_STORE) --progress=false $(FIXTURE_REPRO)
	$(BIN) load $(KG)-1.16.0 --nodes $(FIXTURE_NODES) \
	  --edges $(CLI)/testdata/dakp/edges.drift.ndjson --engine $(FIXTURE_ENGINE) \
	  --store file:$(CLI)/testdata/contract/drift.ndjson --progress=false $(FIXTURE_REPRO)
	$(BIN) load $(KG)-1.16.0 --nodes $(FIXTURE_NODES) \
	  --edges $(CLI)/testdata/dakp/edges.unresolvable.ndjson --engine $(FIXTURE_ENGINE) \
	  --store file:$(CLI)/testdata/contract/unresolvable.ndjson --progress=false $(FIXTURE_REPRO)
	# The dict-compressed twin of docs.ndjson, from a dictionary trained on the fixture itself:
	# this is the byte surface the Elixir dictionary registry is contract-tested against.
	$(BIN) train-dict --nodes $(FIXTURE_NODES) \
	  --edges $(CLI)/testdata/dakp/edges.ndjson --engine $(FIXTURE_ENGINE) \
	  --out $(CLI)/testdata/contract/fixture.dict --samples 64
	$(BIN) load $(KG)-1.11.2 --nodes $(FIXTURE_NODES) \
	  --edges $(CLI)/testdata/dakp/edges.ndjson --engine $(FIXTURE_ENGINE) \
	  --store file:$(CLI)/testdata/contract/dictdocs.ndjson --progress=false $(FIXTURE_REPRO) \
	  --dict $(CLI)/testdata/contract/fixture.dict
	cp $(CLI)/testdata/contract/dictdocs.ndjson $(CLI)/testdata/contract/dictdocs.golden.ndjson
	cp $(CLI)/testdata/contract/docs.ndjson $(CLI)/testdata/contract/docs.golden.ndjson
	@echo "contract fixtures: $$(wc -l < $(CLI)/testdata/contract/docs.ndjson) documents"

contract-test: contract ## Contract fixtures plus the Elixir reader that must agree with them
	mkdir -p $(WEB)/test/fixtures/contract
	cp $(CLI)/testdata/contract/*.ndjson $(CLI)/testdata/contract/*.dict $(WEB)/test/fixtures/contract/
	cd $(WEB) && mix test test/contract_test.exs

# Regeneration is byte-reproducible (fixed reservoir seed and pool clock, sorted pool), so any diff
# here means the Go writer's output changed and the committed fixtures, which the Elixir tests
# read, no longer match it.
.PHONY: contract-check
contract-check: contract-test ## Fail if the committed contract fixtures are stale
	git diff --exit-code -- $(CLI)/testdata/contract $(WEB)/test/fixtures/contract

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

check-fast: ## Offline gate without the embedded-engine tests (for the pre-commit hook)
	@$(MAKE) --no-print-directory go-fmt-check ex-fmt-check go-lint ex-compile go-test-fast

precommit: ## Run every prek hook over the whole tree
	prek run --all-files

# ---------------------------------------------------------------- local run (no cloud)

LOCAL_DOCS ?= $(CURDIR)/tmp/edges.local.ndjson
LOCAL_KEY  ?= $(KG)-$(DAKP_OLD)

.PHONY: local-load local-web
local-load: build ## Encode the DAKP sample to a local docs file (no Cosmos, no RU)
	mkdir -p tmp
	$(BIN) load "$(LOCAL_KEY)" --nodes "$(DAKP_NODES)" --edges "$(DAKP_EDGES)" --store file:$(LOCAL_DOCS)

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
