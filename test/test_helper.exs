# Start every run from an empty database: chat ids in tests come from
# System.unique_integer/0, which repeats across runs.
Application.stop(:dungeon)
File.rm(Application.fetch_env!(:dungeon, :db_path))
{:ok, _} = Application.ensure_all_started(:dungeon)

ExUnit.start()
