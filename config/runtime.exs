import Config

if config_env() != :test do
  token = System.get_env("TELEGRAM_BOT_TOKEN")

  if config_env() == :prod and is_nil(token) do
    raise "TELEGRAM_BOT_TOKEN is not set (get one from @BotFather)"
  end

  config :dungeon,
    token: token,
    db_path: System.get_env("DUNGEON_DB", "data/dungeon.dets")

  config :logger, level: String.to_existing_atom(System.get_env("LOG_LEVEL", "info"))
end
