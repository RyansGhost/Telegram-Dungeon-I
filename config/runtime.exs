# Runtime configuration, read from environment variables each time the app
# starts, including inside the Docker release. See README.md for the full
# list. Tests are configured in config.exs instead.
import Config

if config_env() != :test do
  token = System.get_env("TELEGRAM_BOT_TOKEN")
  database_url = System.get_env("DATABASE_URL")

  # In production the bot is useless without these, so fail fast with a
  # clear message. In development, a missing token just means the poller
  # doesn't start (handy for trying the game in `iex -S mix`), and the
  # database defaults to a local server.
  if config_env() == :prod do
    token || raise "TELEGRAM_BOT_TOKEN is not set (get one from @BotFather)"
    database_url || raise "DATABASE_URL is not set, e.g. postgres://user:pass@host:5432/dungeon"
  end

  config :dungeon, token: token

  config :dungeon, Dungeon.Repo,
    url: database_url || "postgres://postgres:postgres@localhost:5432/dungeon_dev",
    # Connections kept open to the database. Each command uses one briefly,
    # so a handful serves many chats.
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))

  # LOG_LEVEL must be a level Logger knows: debug, info, warning or error.
  config :logger, level: String.to_existing_atom(System.get_env("LOG_LEVEL", "info"))
end
