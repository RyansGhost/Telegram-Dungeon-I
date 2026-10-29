# Telegram Dungeon

[![CI](https://github.com/RyansGhost/Telegram-Dungeon-I/actions/workflows/ci.yml/badge.svg)](https://github.com/RyansGhost/Telegram-Dungeon-I/actions/workflows/ci.yml)

A multiplayer dungeon crawler that runs in Telegram group chats, written in Elixir/OTP.
Each chat gets its own shared, procedurally generated dungeon. Everyone in the group
explores it together: you see who's in the room with you, gang up on monsters, split the loot,
and revive fallen friends, then descend floor by floor as monsters get tougher.

## Playing

Add the bot to a group (or DM it) and send `/join`.

| Command | What it does |
|---|---|
| `/join`, `/leave` | Enter or leave this chat's dungeon |
| `/look` | Describe your room, monsters, loot, and who else is here |
| `/go <dir>` or `/n` `/s` `/e` `/w` | Move. Fleeing a monster may earn you a parting blow |
| `/attack` | Fight. The monster strikes back at a random adventurer in the room |
| `/take`, `/use <item>` | Loot the room; use a `potion`, `elixir`, or `whetstone` |
| `/revive <name>` | Bring a downed ally in your room back to half HP |
| `/rest` | Heal fully, but only at the entrance |
| `/descend` | Once the stairwell guardian is dead, take the whole party down a floor |
| `/status`, `/party` | Your character sheet / the whole party |
| `/newgame` | Reset this chat's dungeon |

XP and gold from a kill are split among everyone standing in the room.

## Deploying (Docker)

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy the token.
2. (Optional) Bots always receive `/commands` in groups, so privacy mode can stay on.
3. Configure and start:

   ```bash
   cp .env.example .env   # then paste your token into .env
   docker compose up -d --build
   docker compose logs -f
   ```

The bot uses **long polling**, so it needs only outbound HTTPS to `api.telegram.org`.
You don't need to open ports, set up a reverse proxy, or have a public URL. Game state lives in a
DETS file on the `dungeon-data` volume (`/data/dungeon.dets`), so it survives restarts and upgrades.

The image is a multi-stage build: an OTP release on `debian:bookworm-slim` running as a non-root
user (uid 1000), with a healthcheck. If you'd rather bind-mount a host directory than use a named
volume, make sure it's writable by uid 1000.

Environment variables:

| Variable | Default | |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | — | Required |
| `DUNGEON_DB` | `/data/dungeon.dets` | State file path |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warning`, `error` |
| `HTTPS_PROXY` | — | Optional outbound proxy, e.g. `http://proxy.lan:3128` |

Back up the game state:

```bash
docker compose cp dungeon:/data/dungeon.dets ./dungeon-backup.dets
```

Attach a remote shell to the running node:

```bash
docker compose exec dungeon bin/dungeon remote
```

## Development

Requires Elixir 1.17+ on OTP 27+. The project has **no third-party dependencies**: it uses OTP's
built-in `:json` and `:httpc`.

```bash
mix test            # full suite
mix test --cover    # with coverage (CI requires 90%+)
TELEGRAM_BOT_TOKEN=... iex -S mix
```

The test suite covers every game rule against a small hand-built dungeon
(`test/support/fixtures.ex`), checks structural invariants of generated floors across
many seeds, and exercises the HTTP client and poller end to end against an in-process
fake Telegram server (`test/support/fake_telegram.ex`), so no network or token is needed.

CI (`.github/workflows/ci.yml`) checks formatting, compiles with warnings as errors,
runs the tests with coverage on Elixir 1.17 and 1.18, and builds the Docker image.

Layout (each module's docs explain how it works; `h Dungeon.Engine` in `iex -S mix` shows them):

- `lib/dungeon/application.ex`: the supervision tree, and how a command flows through it
- `lib/dungeon/structs.ex`: the data model (`State`, `Room`, `Player`, `Monster`)
- `lib/dungeon/world.ex`: seeded procedural floor generation (deterministic per seed + depth)
- `lib/dungeon/engine.ex`: game rules as pure functions over `Dungeon.State`
- `lib/dungeon/game_server.ex`: one GenServer per chat; serializes commands, persists changes, stops when idle
- `lib/dungeon/store.ex`: DETS persistence
- `lib/dungeon/telegram/`: Bot API client, long-poll loop, and command parsing
