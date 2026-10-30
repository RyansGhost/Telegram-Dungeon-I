defmodule Dungeon.Telegram.Poller do
  @moduledoc """
  Long-polls Telegram for updates. Polling (rather than webhooks) means the
  bot needs no inbound port or public URL — ideal behind a homelab NAT.

  The loop: ask Telegram for new messages (it holds the request open for up
  to 30 seconds until something arrives), handle the batch, then ask again.
  Each request acknowledges the previous batch via `offset`, so every update
  is handled once. If Telegram can't be reached, the poller logs a warning
  and tries again in 5 seconds rather than crashing.

  A command that fails (e.g. because the database is unreachable) is logged,
  and the player gets a short apology instead of silence.

  Telegram allows only one poller per bot: if a second copy of the bot is
  running anywhere, the two keep cutting each other off with 409 Conflict
  errors. A webhook set on the bot also causes 409s (delete it first).
  """
  use GenServer
  require Logger

  alias Dungeon.Telegram.{Client, Commands}

  @long_poll_seconds 30
  @retry_after :timer.seconds(5)
  @apology "⚠️ Something went wrong handling that. Please try again in a moment."

  def start_link(token), do: GenServer.start_link(__MODULE__, token, name: __MODULE__)

  # The network work is done in handle_info/2 via messages to self(), so
  # init/1 returns at once and doesn't hold up application startup.
  # `offset` 0 means "everything not yet acknowledged"; `username` is the
  # bot's own name, filled in by :setup.
  @impl true
  def init(token) do
    Client.configure_proxy()
    send(self(), :setup)
    {:ok, %{token: token, offset: 0, username: nil}}
  end

  # Runs once at startup: registers the command menu and learns the bot's
  # username (so commands addressed to other bots can be ignored). Neither
  # is fatal if it fails: commands still work without the menu, and without
  # a username every mention is accepted.
  @impl true
  def handle_info(:setup, state) do
    case Client.set_my_commands(state.token, Commands.menu()) do
      {:ok, _} -> Logger.info("Registered bot command menu")
      {:error, reason} -> Logger.warning("setMyCommands failed: #{inspect(reason)}")
    end

    username =
      case Client.get_me(state.token) do
        {:ok, %{"username" => username}} ->
          Logger.info("Running as @#{username}")
          username

        other ->
          Logger.warning("getMe failed: #{inspect(other)}; accepting commands for any bot")
          nil
      end

    send(self(), :poll)
    {:noreply, %{state | username: username}}
  end

  # One iteration of the polling loop. On success, poll again immediately
  # (the long poll itself does the waiting); on failure, back off first.
  def handle_info(:poll, state) do
    case Client.get_updates(state.token, state.offset, @long_poll_seconds) do
      {:ok, updates} ->
        dispatch(state, updates)
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
  defp dispatch(state, updates) do
    Dungeon.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      updates |> Enum.group_by(&chat_id/1) |> Map.values(),
      fn chat_updates -> Enum.each(chat_updates, &handle_update(state, &1)) end,
      max_concurrency: 16,
      timeout: :timer.seconds(60),
      on_timeout: :kill_task
    )
    |> Stream.run()
  end

  # Handles one update and sends the reply, if there is one.
  defp handle_update(state, update) do
    case Commands.handle(update, state.username) do
      {chat_id, reply} -> reply(state.token, chat_id, reply)
      nil -> :ok
    end
  rescue
    e -> failed(state.token, update, Exception.format(:error, e, __STACKTRACE__))
  catch
    # A GameServer that crashed mid-command (e.g. because a database write
    # failed) arrives here as an exit.
    :exit, reason -> failed(state.token, update, Exception.format_exit(reason))
  end

  # A command that failed: log it, and apologise to the chat so the player
  # isn't left waiting. The chat's later updates still run.
  defp failed(token, update, details) do
    Logger.error("Update #{update["update_id"]} failed: #{details}")
    if chat = chat_id(update), do: reply(token, chat, @apology)
  end

  defp reply(token, chat_id, text) do
    with {:error, reason} <- Client.send_message(token, chat_id, text) do
      Logger.warning("sendMessage to #{chat_id} failed: #{inspect(reason)}")
    end
  end

  # The chat an update came from, or nil for updates that aren't messages.
  defp chat_id(update), do: get_in(update, ["message", "chat", "id"])
end
