defmodule Dungeon.Application do
  @moduledoc """
  OTP application entry point: starts the supervision tree.

  How a Telegram command flows through the processes started here:

      Telegram.Poller ──> Telegram.Commands ──> GameServer (one per chat)
       (long-polls,        (parses the            (runs Engine rules,
        replies)            command)               saves via Store ──> PostgreSQL)

  The children start in order, each relying on the ones before it:

    * `Dungeon.Repo` - the pool of connections to PostgreSQL
    * `Ecto.Migrator` - brings the database schema up to date (runs any
      migrations in priv/repo/migrations not yet applied), then exits. Set
      `SKIP_MIGRATIONS=true` to manage migrations by hand instead.
    * `Dungeon.Registry` - maps chat ids to their `Dungeon.GameServer`
      processes
    * `Dungeon.GameSupervisor` - starts a `Dungeon.GameServer` for each chat
      on demand
    * `Dungeon.TaskSupervisor` - runs the poller's per-chat worker tasks
    * `Dungeon.Telegram.Poller` - fetches messages from Telegram. It only
      starts if a bot token is configured, so tests and `iex -S mix` without
      a token run the game without connecting to Telegram.
  """
  use Application

  @impl true
  def start(_type, _args) do
    token = Application.get_env(:dungeon, :token)

    children =
      [
        Dungeon.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:dungeon, :ecto_repos),
         skip: System.get_env("SKIP_MIGRATIONS") == "true"},
        {Registry, keys: :unique, name: Dungeon.Registry},
        {DynamicSupervisor, name: Dungeon.GameSupervisor, strategy: :one_for_one},
        {Task.Supervisor, name: Dungeon.TaskSupervisor}
      ] ++ if(token, do: [{Dungeon.Telegram.Poller, token}], else: [])

    # :one_for_one: if a child crashes, only that child is restarted.
    Supervisor.start_link(children, strategy: :one_for_one, name: Dungeon.Supervisor)
  end
end
