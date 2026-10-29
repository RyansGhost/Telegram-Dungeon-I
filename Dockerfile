# syntax=docker/dockerfile:1

# ---- Build stage: compile a self-contained OTP release ----
FROM elixir:1.17-otp-27-slim AS build

ENV MIX_ENV=prod
WORKDIR /app

COPY mix.exs ./
COPY config config
COPY lib lib
RUN mix release

# ---- Runtime stage: just the release, no Elixir toolchain ----
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    DUNGEON_DB=/data/dungeon.dets

RUN useradd --system --uid 1000 --home /app dungeon \
 && mkdir /data && chown dungeon /data

WORKDIR /app
COPY --from=build --chown=dungeon /app/_build/prod/rel/dungeon ./

USER dungeon
VOLUME /data

HEALTHCHECK --interval=60s --timeout=10s CMD ["/app/bin/dungeon", "pid"]
CMD ["/app/bin/dungeon", "start"]
