# syntax=docker/dockerfile:1.7
# Multi-stage build for Phoenix 1.8 (Elixir 1.18 / OTP 27).
# Local-first quickstart: `docker compose up --build`. See DEPLOYMENT.md.

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3
ARG DEBIAN_VERSION=bookworm-20250520-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ---- builder: fetch deps, build assets, mix release ----
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git curl ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Cache deps independently of source changes
COPY mix.exs mix.lock ./
RUN mix deps.get --only ${MIX_ENV}
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# App sources
COPY priv priv
COPY lib lib
COPY assets assets

# Asset binaries (tailwind, esbuild) + minified bundle + phx.digest
RUN mix assets.setup && mix assets.deploy

# Runtime config is read at boot, but must be copied before release
COPY config/runtime.exs config/

RUN mix compile && mix release

# ---- runner: minimal runtime image with just the release ----
FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

RUN groupadd --system --gid 1001 phoenix \
 && useradd  --system --uid 1001 --gid phoenix --home-dir /app phoenix \
 && chown phoenix:phoenix /app

USER phoenix

COPY --from=builder --chown=phoenix:phoenix /app/_build/prod/rel/scheduling ./

ENV PHX_SERVER=true
ENV PORT=4000
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://localhost:4000/api/health || exit 1

# Migrate then start the release.
CMD ["sh", "-c", "/app/bin/scheduling eval 'Scheduling.Release.migrate()' && /app/bin/scheduling start"]
