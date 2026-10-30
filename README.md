# Telegram Dungeon

[![CI](https://github.com/RyansGhost/Telegram-Dungeon-I/actions/workflows/ci.yml/badge.svg)](https://github.com/RyansGhost/Telegram-Dungeon-I/actions/workflows/ci.yml)

A multiplayer dungeon crawler that runs in Telegram group chats, written in Elixir/OTP.
Each chat gets its own shared, procedurally generated dungeon. Everyone in the group
explores it together: you see who's in the room with you, gang up on monsters, split the loot,
and revive fallen friends, then descend floor by floor as monsters get tougher.

## Playing

Add the bot to a group (or DM it) and send `/join`.

Commands are case-insensitive and the slash is optional: `/look`, `Look` and `look!` all work.
Without a slash, a message only counts if it is exactly a command (`look`, `go north`,
`use potion`), so ordinary chat like "look at this" is ignored. `/newgame` always needs its slash.
In groups with several bots, commands addressed to another bot (`/look@OtherBot`) are ignored.

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
2. (Optional) To use commands **without the slash in groups**, turn off privacy mode: in
   @BotFather, send `/setprivacy`, pick the bot, choose **Disable**, then remove the bot from each
   group and add it back (the change only applies when it joins). With privacy mode on, Telegram only
   delivers messages starting with `/` to bots in groups. Slash commands, and everything in direct
   messages, work either way.
3. Configure and start:

   ```bash
   cp .env.example .env   # then set TELEGRAM_BOT_TOKEN and POSTGRES_PASSWORD in .env
   docker compose up -d --build
   docker compose logs -f
   ```

This starts two containers: the bot, and **PostgreSQL 17**, which stores every chat's dungeon and
every player's progress. The bot waits for the database to be healthy, then creates or upgrades its
tables automatically (migrations in `priv/repo/migrations`) before it starts answering.

The bot uses **long polling**, so it needs only outbound HTTPS to `api.telegram.org`.
You don't need to open ports, set up a reverse proxy, or have a public URL. The database isn't
exposed outside compose's private network either. Its files live on the `db-data` volume, so they
survive restarts, rebuilds and `docker compose down` (but not `down -v`).

The bot image is a multi-stage build: an OTP release on `debian:bookworm-slim` running as a
non-root user, with a healthcheck.

Environment variables (in `.env`):

| Variable | Default | |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | — | Required |
| `POSTGRES_PASSWORD` | — | Required. Database password, set when the database is first created |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warning`, `error` |
| `HTTPS_PROXY` | — | Optional outbound proxy, e.g. `http://proxy.lan:3128` |
| `POOL_SIZE` | `5` | Database connections to keep open |
| `SKIP_MIGRATIONS` | — | Set to `true` to stop the bot migrating the database on startup |

`DATABASE_URL` is set by `compose.yaml`. Set it yourself to use a PostgreSQL server of your own instead
of the bundled one (and remove the `db` service).

### Database

What's stored: `dungeons` (one row per chat: seed, depth, entrance), `players` (one row per player per
chat: HP, level, XP, gold, inventory, location) and `rooms` (the current floor, including monsters' HP
and loot on the floor). Open a SQL shell:

```bash
docker compose exec db psql -U dungeon dungeon
```

```sql
SELECT name, level, xp, gold, inventory FROM players ORDER BY level DESC;
```

Back up and restore:

```bash
docker compose exec -T db pg_dump -U dungeon dungeon > dungeon-backup.sql
```

```bash
docker compose exec -T db psql -U dungeon dungeon < dungeon-backup.sql
```

The `postgres` image is pinned to major version 17. Moving to a newer major version needs a
dump and restore: take a backup, change the image tag, delete the `db-data` volume, start, then restore.

Attach a remote shell to the running bot:

```bash
docker compose exec dungeon bin/dungeon remote
```

## Development

Requires Elixir 1.17+ on OTP 27+, and a PostgreSQL server. Dependencies are Ecto and Postgrex
(database access) and Jason (JSON); Telegram calls use OTP's built-in `:httpc`. By default the
app expects a local PostgreSQL with the `postgres`/`postgres` login; override with
`TEST_DATABASE_URL` (tests) or `DATABASE_URL` (development). A throwaway one:

```bash
docker run -d --name dungeon-pg -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:17-alpine
```

```bash
mix deps.get
mix test            # creates and migrates the test database, then runs the suite
mix test --cover    # with coverage (CI requires 90%+)
mix ecto.create && TELEGRAM_BOT_TOKEN=... iex -S mix
```

The test suite covers every game rule against a small hand-built dungeon
(`test/support/fixtures.ex`), checks structural invariants of generated floors across
many seeds, checks that saves to PostgreSQL round-trip exactly (including through a scripted game
and a failed, rolled-back save), and exercises the HTTP client and poller end to end against an
in-process fake Telegram server (`test/support/fake_telegram.ex`), so no token is needed.

CI (`.github/workflows/ci.yml`) checks formatting, compiles with warnings as errors,
runs the tests with coverage on Elixir 1.17 and 1.18 against a PostgreSQL service container, and
builds the Docker image.

Layout (each module's docs explain how it works; `h Dungeon.Engine` in `iex -S mix` shows them):

- `lib/dungeon/application.ex`: the supervision tree, and how a command flows through it
- `lib/dungeon/structs.ex`: the data model (`State`, `Room`, `Player`, `Monster`)
- `lib/dungeon/world.ex`: seeded procedural floor generation (deterministic per seed + depth)
- `lib/dungeon/engine.ex`: game rules as pure functions over `Dungeon.State`
- `lib/dungeon/game_server.ex`: one GenServer per chat; serializes commands, persists changes, stops when idle
- `lib/dungeon/store.ex`: PostgreSQL persistence (incremental, transactional saves); `repo.ex` and
  `store/schemas.ex` define the connection and tables, `priv/repo/migrations/` the schema
- `lib/dungeon/telegram/`: Bot API client, long-poll loop, and command parsing
