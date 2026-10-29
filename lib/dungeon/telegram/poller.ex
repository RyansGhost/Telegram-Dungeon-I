defmodule Dungeon.Telegram.Poller do
  @moduledoc """
  Long-polls Telegram for updates. Polling (rather than webhooks) means the
  bot needs no inbound port or public URL — ideal behind a homelab NAT.

  The loop: ask Telegram for new messages (it holds the request open for up
  to 30 seconds until something arrives), handle the batch, then ask again.
  Each request acknowledges the previous batch via `offset`, so every update
  is handled once. If Telegram can't be reached, the poller logs a warning
  and tries again in 5 seconds rather than crashing.

  Telegram allows only one poller per bot: if a second copy of the bot is
  running anywhere, the two keep cutting each other off with 409 Conflict
  errors. A webhook set on the bot also causes 409s (delete it first).
  """
  use GenServer
  require Logger

  alias Dungeon.Telegram.{Client, Commands}

  @long_poll_seconds 30
  @retry_after :timer.seconds(5)

  def start_link(token), do: GenServer.start_link(__MODULE__, token, name: __MODULE__)

  # The network work is done in handle_info/2 via messages to self(), so
  # init/1 returns at once and doesn't hold up application startup.
  # `offset` 0 means "everything not yet acknowledged".
  @impl true
  def init(token) do
    Client.configure_proxy()
    send(self(), :register_commands)
    {:ok, %{token: token, offset: 0}}
  end

  # Runs once at startup. A failure here isn't fatal: commands still work
  # without the menu.
  @impl true
  def handle_info(:register_commands, state) do
    case Client.set_my_commands(state.token, Commands.menu()) do
      {:ok, _} -> Logger.info("Registered bot command menu")
      {:error, reason} -> Logger.warning("setMyCommands failed: #{inspect(reason)}")
    end

    send(self(), :poll)
    {:noreply, state}
  end

  # One iteration of the polling loop. On success, poll again immediately
  # (the long poll itself does the waiting); on failure, back off first.
  def handle_info(:poll, state) do
    case Client.get_updates(state.token, state.offset, @long_poll_seconds) do
      {:ok, updates} ->
        dispatch(state.token, updates)
        send(self(), :poll)
        {:noreply, %{state | offset: next_offset(updates, state.offset)}}

      {:error, reason} ->
        Logger.warning("getUpdates failed: #{inspect(reason)}; retrying")
        Process.send_after(self(), :poll, @retry_after)
        {:noreply, state}
    end
  end

  # Updates arrive in ascending id order, so the next offset is one past the
  # last. An empty batch acknowledges nothing new.
  defp next_offset([], offset), do: offset
  defp next_offset(updates, _offset), do: List.last(updates)["update_id"] + 1

  # Updates run in order within a chat (so commands apply, and replies
  # arrive, in the order they were sent) and concurrently across chats.
  # The batch finishes before the next poll.
  #
  # Each chat's updates are handled by one task; up to 16 chats run at once.
  # Tasks are "nolink": a task that crashes or takes over 60 s is killed and
  # skipped without taking the poller down with it.
  defp dispatch(token, updates) do
    Dungeon.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      updates |> Enum.group_by(&get_in(&1, ["message", "chat", "id"])) |> Map.values(),
      fn chat_updates -> Enum.each(chat_updates, &handle_update(token, &1)) end,
      max_concurrency: 16,
      timeout: :timer.seconds(60),
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  # Handles one update and sends the reply, if there is one. A command that
  # raises is logged and skipped, so the chat's later updates still run.
  defp handle_update(token, update) do
    with {chat_id, reply} <- Commands.handle(update),
         {:error, reason} <- Client.send_message(token, chat_id, reply) do
      Logger.warning("sendMessage to #{chat_id} failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error(
        "Update #{update["update_id"]} failed: " <> Exception.format(:error, e, __STACKTRACE__)
      )
  end
end
