defmodule Dungeon.GameServer do
  @moduledoc """
  One process per chat. Commands for a chat are serialized through it, so
  simultaneous players can't clobber each other's moves. Idle servers stop
  after a while and are restarted from the store on the next command.
  """
  use GenServer, restart: :transient

  alias Dungeon.{Engine, Store}

  @idle_timeout :timer.minutes(30)

  def start_link(chat_id), do: GenServer.start_link(__MODULE__, chat_id, name: via(chat_id))

  @doc """
  Runs `fun` (state -> `{:ok, state, reply}` | `{:error, reply}`) against the
  chat's dungeon, persisting any change. Returns the reply text.
  """
  def run(chat_id, fun, retries \\ 1) do
    GenServer.call(ensure_started(chat_id), {:run, fun})
  catch
    # The server may have just stopped for idleness; start it again.
    :exit, {reason, _} when reason in [:noproc, :normal] and retries > 0 ->
      run(chat_id, fun, retries - 1)
  end

  def reset(chat_id) do
    run(chat_id, fn _ ->
      {:ok, Engine.new(chat_id),
       "🌑 A new dungeon has been carved out of the earth. Use /join to enter."}
    end)
  end

  defp via(chat_id), do: {:via, Registry, {Dungeon.Registry, chat_id}}

  defp ensure_started(chat_id) do
    case DynamicSupervisor.start_child(Dungeon.GameSupervisor, {__MODULE__, chat_id}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @impl true
  def init(chat_id) do
    {:ok, Store.load(chat_id) || Engine.new(chat_id), @idle_timeout}
  end

  @impl true
  def handle_call({:run, fun}, _from, state) do
    case fun.(state) do
      {:ok, ^state, reply} ->
        {:reply, reply, state, @idle_timeout}

      {:ok, new_state, reply} ->
        Store.save(new_state)
        {:reply, reply, new_state, @idle_timeout}

      {:error, reply} ->
        {:reply, reply, state, @idle_timeout}
    end
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}
end
