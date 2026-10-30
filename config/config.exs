# Compile-time configuration, read when the project is built.
# Settings that come from environment variables (the bot token, the
# database URL) belong in runtime.exs instead, so a built release can be
# configured without rebuilding.
import Config

config :logger, :default_formatter, format: "$time [$level] $message\n"

# Tells `mix ecto.*` tasks which repositories this app has.
config :dungeon, ecto_repos: [Dungeon.Repo]

if config_env() == :test do
  # Tests never connect to Telegram: with no token, Dungeon.Application
  # doesn't start the poller. They need a PostgreSQL server; by default a
  # local one with the stock postgres/postgres login, as in CI.
  config :dungeon, token: nil

  config :dungeon, Dungeon.Repo,
    url:
      System.get_env(
        "TEST_DATABASE_URL",
        "postgres://postgres:postgres@localhost:5432/dungeon_test"
      ),
    pool_size: 10

  # Hide info logs (including Ecto's migration messages), but keep warnings
  # visible.
  config :logger, level: :warning
end
