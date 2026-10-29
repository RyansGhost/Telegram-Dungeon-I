defmodule Dungeon.Telegram.Poller do
  @moduledoc """
  Long-polls Telegram for updates. Polling (rather than webhooks) means the
  bot needs no inbound port or public URL — ideal behind a homelab NAT.
  """
  use GenServer
  require Logger

  alias Dungeon.Telegram.{Client, Commands}

  @long_poll_seconds 30
  @retry_after :timer.seconds(5)

  def start_link(token), do: GenServer.start_link(__MODULE__, token, name: __MODULE__)

  @impl true
  def init(token) do
    send(self(), :register_commands)
    {:ok, %{token: token, offset: 0}}
  end

  @impl true
  def handle_info(:register_commands, state) do
    case Client.set_my_commands(state.token, Commands.menu()) do
      {:ok, _} -> Logger.info("Registered bot command menu")
      {:error, reason} -> Logger.warning("setMyCommands failed: #{inspect(reason)}")
    end

    send(self(), :poll)
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    case Client.get_updates(state.token, state.offset, @long_poll_seconds) do
      {:ok, updates} ->
        Enum.each(updates, &dispatch(state.token, &1))
        send(self(), :poll)
        {:noreply, %{state | offset: next_offset(updates, state.offset)}}

      {:error, reason} ->
        Logger.warning("getUpdates failed: #{inspect(reason)}; retrying")
        Process.send_after(self(), :poll, @retry_after)
        {:noreply, state}
    end
  end

  defp next_offset([], offset), do: offset
  defp next_offset(updates, _offset), do: List.last(updates)["update_id"] + 1

  defp dispatch(token, update) do
    Task.Supervisor.start_child(Dungeon.TaskSupervisor, fn ->
      with {chat_id, reply} <- Commands.handle(update),
           {:error, reason} <- Client.send_message(token, chat_id, reply) do
        Logger.warning("sendMessage to #{chat_id} failed: #{inspect(reason)}")
      end
    end)
  end
end
