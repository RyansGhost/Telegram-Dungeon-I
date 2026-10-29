defmodule Dungeon.Store do
  @moduledoc """
  Persists each chat's `Dungeon.State` in a DETS file (no external database).
  This process owns the table; any process may read and write it.
  """
  use GenServer

  @table :dungeons

  def start_link(path), do: GenServer.start_link(__MODULE__, path, name: __MODULE__)

  def load(chat_id) do
    case :dets.lookup(@table, chat_id) do
      [{^chat_id, state}] -> state
      [] -> nil
    end
  end

  def save(%Dungeon.State{chat_id: chat_id} = state) do
    :ok = :dets.insert(@table, {chat_id, state})
    :dets.sync(@table)
  end

  @impl true
  def init(path) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(Path.dirname(path))
    {:ok, @table} = :dets.open_file(@table, file: String.to_charlist(path), type: :set)
    {:ok, path}
  end

  @impl true
  def terminate(_reason, _path), do: :dets.close(@table)
end
