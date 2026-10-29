defmodule Dungeon.Application do
  @moduledoc """
  OTP application entry point: starts the supervision tree.

  How a Telegram command flows through the processes started here:

      Telegram.Poller ──> Telegram.Commands ──> GameServer (one per chat)
       (long-polls,        (parses the            (runs Engine rules,
        replies)            command)               saves via Store)

  The children start in order, each relying on the ones before it:

    * `Dungeon.Registry` - maps chat ids to their `Dungeon.GameServer`
      processes
    * `Dungeon.Store` - opens the DETS file that saves every dungeon
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
        {Registry, keys: :unique, name: Dungeon.Registry},
        {Dungeon.Store, Application.fetch_env!(:dungeon, :db_path)},
        {DynamicSupervisor, name: Dungeon.GameSupervisor, strategy: :one_for_one},
        {Task.Supervisor, name: Dungeon.TaskSupervisor}
      ] ++ if(token, do: [{Dungeon.Telegram.Poller, token}], else: [])

    # :one_for_one: if a child crashes, only that child is restarted.
    Supervisor.start_link(children, strategy: :one_for_one, name: Dungeon.Supervisor)
  end
end
