# Build configuration for the project (Mix is Elixir's build tool).
defmodule Dungeon.MixProject do
  use Mix.Project

  def project do
    [
      app: :dungeon,
      version: "0.1.0",
      elixir: "~> 1.17",
      # In production, stop the whole node if the app crashes beyond what its
      # supervisors can recover from (Docker's restart policy takes over).
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      # `mix test --cover` fails below 90%. Plain structs and test helpers
      # are excluded: they have nothing meaningful to cover.
      test_coverage: [
        summary: [threshold: 90],
        ignore_modules: [Dungeon.Room, Dungeon.State, Dungeon.Fixtures, Dungeon.FakeTelegram]
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

  # No third-party deps: OTP 27 ships :json and an HTTPS client (:httpc).
  defp deps, do: []
end
