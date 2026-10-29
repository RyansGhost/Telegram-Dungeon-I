defmodule Dungeon.GameServer do
  @moduledoc """
  One process per chat, holding that chat's `Dungeon.State` in memory.

  Commands for a chat are serialized through it (a GenServer handles one
  message at a time), so simultaneous players can't clobber each other's
  moves. Every change is saved to `Dungeon.Store` before the reply goes out.

  Servers start on a chat's first command, and stop after 30 minutes without
  one to free memory. The next command starts a new server, which reloads
  the state from the store.
  """
  # :transient - the supervisor restarts the server only if it crashes, not
  # when it stops normally after being idle.
  use GenServer, restart: :transient

  alias Dungeon.{Engine, Store}

  @idle_timeout :timer.minutes(30)

  def start_link(chat_id), do: GenServer.start_link(__MODULE__, chat_id, name: via(chat_id))

  @doc """
  Runs `fun` (state -> `{:ok, state, reply}` | `{:error, reply}`) against the
  chat's dungeon, persisting any change. Returns the reply text.

  `fun` is normally a `Dungeon.Engine` action with the player's arguments
  already filled in, e.g. `&Engine.move(&1, user_id, "north")`.
  """
  def run(chat_id, fun, retries \\ 1) do
    GenServer.call(ensure_started(chat_id), {:run, fun})
  catch
    # The server may have stopped for idleness between ensure_started/1
    # finding it and the call arriving. Start a new one and try once more.
    :exit, {reason, _} when reason in [:noproc, :normal] and retries > 0 ->
      run(chat_id, fun, retries - 1)
  end

  @doc "Replaces the chat's dungeon with a brand-new one (`/newgame`)."
  def reset(chat_id) do
    run(chat_id, fn _ ->
      {:ok, Engine.new(chat_id),
       "🌑 A new dungeon has been carved out of the earth. Use /join to enter."}
    end)
  end

  # Registers each server under its chat id, so it can be found by chat id
  # alone (see Dungeon.Registry in Dungeon.Application).
  defp via(chat_id), do: {:via, Registry, {Dungeon.Registry, chat_id}}

  # Returns the chat's server, starting it first if needed. Starting is
  # always attempted, and the registry turns a duplicate into
  # :already_started, so two simultaneous first commands can't create two
  # servers.
  defp ensure_started(chat_id) do
    case DynamicSupervisor.start_child(Dungeon.GameSupervisor, {__MODULE__, chat_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # Resume the saved dungeon, or create one for a chat that's never played.
  # Returning a timeout from a callback makes OTP send :timeout (see
  # handle_info/2) if no other message arrives within that time.
  @impl true
  def init(chat_id) do
    {:ok, Store.load(chat_id) || Engine.new(chat_id), @idle_timeout}
  end

  @impl true
  def handle_call({:run, fun}, _from, state) do
    case fun.(state) do
      # Read-only actions (look, status, ...) return the same state: skip
      # the disk write.
      {:ok, ^state, reply} ->
        {:reply, reply, state, @idle_timeout}

      {:ok, new_state, reply} ->
        Store.save(new_state)
        {:reply, reply, new_state, @idle_timeout}

      {:error, reply} ->
        {:reply, reply, state, @idle_timeout}
    end
  end

  # Idle for @idle_timeout: stop. The state is already saved.
  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}
end
