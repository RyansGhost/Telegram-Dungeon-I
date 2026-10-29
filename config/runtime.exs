# Runtime configuration, read from environment variables each time the app
# starts, including inside the Docker release. See README.md for the full
# list. Tests are configured in config.exs instead.
import Config

if config_env() != :test do
  token = System.get_env("TELEGRAM_BOT_TOKEN")

  # In production the bot is useless without a token, so fail fast with a
  # clear message. In development, a missing token just means the poller
  # doesn't start (handy for trying the game in `iex -S mix`).
  if config_env() == :prod and is_nil(token) do
    raise "TELEGRAM_BOT_TOKEN is not set (get one from @BotFather)"
  end

  config :dungeon,
    token: token,
    # Where saved games live. The Docker image sets this to /data/dungeon.dets.
    db_path: System.get_env("DUNGEON_DB", "data/dungeon.dets")

  # LOG_LEVEL must be a level Logger knows: debug, info, warning or error.
  config :logger, level: String.to_existing_atom(System.get_env("LOG_LEVEL", "info"))
end
