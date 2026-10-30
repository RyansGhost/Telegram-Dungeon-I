# syntax=docker/dockerfile:1
#
# Two stages: compile with the full Elixir toolchain, then copy only the
# finished release into a slim Debian image. The result runs without Elixir
# installed and is a fraction of the toolchain image's size.
#
# This image is the bot only. PostgreSQL runs in its own container; see
# compose.yaml.

# ---- Build stage: compile a self-contained OTP release ----
FROM elixir:1.17-otp-27-slim AS build

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Fetch and compile dependencies before copying the app's own code, so this
# slow layer is cached until mix.exs, mix.lock or the config changes.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

# priv holds the database migrations, which the release runs on startup.
# Tests and test/support aren't needed for the release.
COPY priv priv
COPY lib lib
RUN mix release

# ---- Runtime stage: just the release, no Elixir toolchain ----
# Must use the same Debian release as the build image (bookworm), because the
# bundled Erlang runtime links against its system libraries.
FROM debian:bookworm-slim

# Shared libraries the Erlang runtime needs, plus ca-certificates so HTTPS
# connections to Telegram can be verified.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Erlang needs a UTF-8 locale to handle emoji and other non-ASCII text.
ENV LANG=C.UTF-8

# Run as an unprivileged user. All state lives in PostgreSQL, so the
# container itself needs no writable volume.
RUN useradd --system --uid 1000 --home /app dungeon

WORKDIR /app
COPY --from=build --chown=dungeon /app/_build/prod/rel/dungeon ./

USER dungeon

# `bin/dungeon pid` asks the running node for its OS process id, so it only
# succeeds while the app is up and responsive.
HEALTHCHECK --interval=60s --timeout=10s CMD ["/app/bin/dungeon", "pid"]
CMD ["/app/bin/dungeon", "start"]
