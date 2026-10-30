# Build configuration for the project (Mix is Elixir's build tool).
defmodule Dungeon.MixProject do
  use Mix.Project

  def project do
    [
      app: :dungeon,
      version: "0.2.0",
      elixir: "~> 1.17",
      # In production, stop the whole node if the app crashes beyond what its
      # supervisors can recover from (Docker's restart policy takes over).
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      # `mix test --cover` fails below 90%. Plain structs, declarative schemas
      # and test helpers are excluded: they have nothing meaningful to cover.
      test_coverage: [
        summary: [threshold: 90],
        ignore_modules: [
          Dungeon.Room,
          Dungeon.State,
          Dungeon.Repo,
          Dungeon.Store.DungeonRow,
          Dungeon.Store.PlayerRow,
          Dungeon.Store.RoomRow,
          Dungeon.Fixtures,
          Dungeon.FakeTelegram
        ]
      ],
      deps: deps(),
      # `mix release` builds a self-contained bundle (including the Erlang
      # runtime) at _build/prod/rel/dungeon; the Dockerfile ships that.
      releases: [dungeon: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      # :inets provides the :httpc HTTP client; :ssl adds HTTPS support.
      extra_applications: [:logger, :inets, :ssl],
      mod: {Dungeon.Application, []}
    ]
  end

  # Test-only helper modules (fixtures, the fake Telegram server) live in
  # test/support and are compiled only for the test environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Database access: Ecto for queries and migrations, Postgrex as the
      # PostgreSQL driver, Jason for encoding JSONB columns.
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"}
    ]
  end

  # `mix test` creates and migrates the test database first, so a fresh
  # checkout only needs a running PostgreSQL.
  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
