defmodule Dungeon.Application do
  @moduledoc false
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

    Supervisor.start_link(children, strategy: :one_for_one, name: Dungeon.Supervisor)
  end
end
