# Compile-time configuration, read when the project is built.
# Settings that come from environment variables (the bot token, file paths)
# belong in runtime.exs instead, so a built release can be configured
# without rebuilding.
import Config

config :logger, :default_formatter, format: "$time [$level] $message\n"

if config_env() == :test do
  # Tests use a throwaway database and never connect to Telegram: with no
  # token, Dungeon.Application doesn't start the poller.
  config :dungeon, db_path: "tmp/test.dets", token: nil
  # Hide info logs, but keep warnings visible.
  config :logger, level: :warning
end
