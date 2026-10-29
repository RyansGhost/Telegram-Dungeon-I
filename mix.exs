defmodule Dungeon.MixProject do
  use Mix.Project

  def project do
    [
      app: :dungeon,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [dungeon: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Dungeon.Application, []}
    ]
  end

  # No third-party deps: OTP 27 ships :json and an HTTPS client (:httpc).
  defp deps, do: []
end
