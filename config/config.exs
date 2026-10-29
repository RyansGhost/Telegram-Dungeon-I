import Config

config :logger, :default_formatter, format: "$time [$level] $message\n"

if config_env() == :test do
  config :dungeon, db_path: "tmp/test.dets", token: nil
  config :logger, level: :warning
end
