# Build for the Phoenix app in web/, from the repo root so kgs/ lands inside the build
# context: the display configs compile into the release at build time (display.ex loads
# kgs/*.exs under @external_resource), so the runtime image carries no editable config.
# Base matches the development toolchain exactly: Elixir 1.19.6 on OTP 28.5.0.7, Debian
# bookworm slim.

# ---- deps: fetch once; only mix.exs/mix.lock invalidate this layer ---------------------
FROM docker.io/hexpm/elixir:1.19.6-erlang-28.5.0.7-debian-bookworm-20261005-slim AS deps
WORKDIR /app/web
ENV MIX_ENV=prod
# git: heroicons and daisyui are git deps.
RUN apt-get update -y && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY web/mix.exs web/mix.lock ./
RUN mix deps.get --only prod

# ---- build: compile, digest assets, assemble the release -------------------------------
FROM deps AS build
WORKDIR /app
COPY web ./web
COPY kgs ./kgs
WORKDIR /app/web
# compile first: the phoenix_live_view compiler writes the colocated CSS that the
# tailwind input imports, and the display configs are loaded here via @external_resource.
RUN mix deps.compile && mix compile
RUN mix assets.deploy
RUN mix release

# ---- runtime ---------------------------------------------------------------------------
FROM docker.io/debian:bookworm-20261005-slim AS runtime
# libstdc++/libncurses for the BEAM VM, openssl + ca-certificates for Finch's TLS to Cosmos.
RUN apt-get update -y && apt-get install -y --no-install-recommends \
  libstdc++6 libncurses6 openssl ca-certificates tzdata \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd -r app && useradd -r -g app app
WORKDIR /app
COPY --from=build --chown=app:app /app/web/_build/prod/rel/edge_linkouts /app
USER app
# The release stays stopped in the image; PHX_SERVER=true (set by fly.toml [env]) starts the
# endpoint at boot. PORT must match fly.toml's http_service.internal_port (8080).
ENV MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=8080
EXPOSE 8080
CMD ["/app/bin/edge_linkouts", "start"]
