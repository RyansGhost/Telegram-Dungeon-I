defmodule Dungeon.Store do
  @moduledoc """
  Persists each chat's `Dungeon.State` in a DETS file (no external database).

  DETS is Erlang's built-in on-disk key-value table. Each entry is
  `{chat_id, state}`, with the struct stored as-is, so there is no schema or
  serialization code. The catch: if the structs in `Dungeon.State` and
  friends change shape in a later version, old saves need migrating.

  This process owns the table, opening it on start and closing it cleanly on
  shutdown. Any process may read and write it.
  """
  use GenServer

  # The table is registered under this name, so callers don't need a pid.
  @table :dungeons

  def start_link(path), do: GenServer.start_link(__MODULE__, path, name: __MODULE__)

  @doc "Returns the saved dungeon for `chat_id`, or `nil` if there isn't one."
  def load(chat_id) do
    case :dets.lookup(@table, chat_id) do
      [{^chat_id, state}] -> state
      [] -> nil
    end
  end

  @doc """
  Saves (or overwrites) a chat's dungeon, and flushes it to disk straight
  away so a crash or power cut can't lose it.
  """
  def save(%Dungeon.State{chat_id: chat_id} = state) do
    :ok = :dets.insert(@table, {chat_id, state})
    :dets.sync(@table)
  end

  @impl true
  def init(path) do
    # Trap exits so terminate/2 runs on shutdown and the file is closed
    # properly. (After an unclean stop, DETS repairs the file on next open.)
    Process.flag(:trap_exit, true)
    File.mkdir_p!(Path.dirname(path))
    {:ok, @table} = :dets.open_file(@table, file: String.to_charlist(path), type: :set)
    {:ok, path}
  end

  @impl true
  def terminate(_reason, _path), do: :dets.close(@table)
end
