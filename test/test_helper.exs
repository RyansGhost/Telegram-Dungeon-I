# Start every run from an empty database: chat ids in tests come from
# System.unique_integer/0, which repeats across runs. (The `mix test` alias
# has already created and migrated the test database.)
Dungeon.Repo.query!("TRUNCATE dungeons, players, rooms")

ExUnit.start()
