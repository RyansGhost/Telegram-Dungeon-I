# The polling loop, end to end: a real Poller talks to Dungeon.FakeTelegram,
# which feeds it scripted batches of updates and reports every request
# (including the bot's replies) back to the test.
defmodule Dungeon.Telegram.PollerTest do
  # Not async: the poller is a named process and uses the global API base.
  use ExUnit.Case

  @moduletag :capture_log

  alias Dungeon.FakeTelegram
  alias Dungeon.Telegram.Poller

  setup do
    on_exit(fn -> Application.delete_env(:dungeon, :api_base) end)
    %{chat: System.unique_integer()}
  end

  # Serves `batches` of updates in order, then empty polls. Empty responses
  # are delayed slightly so the poller doesn't spin while the test waits.
  defp fake_telegram(batches) do
    {:ok, queue} = Agent.start_link(fn -> batches end)

    {_pid, base} =
      FakeTelegram.start(fn
        "getUpdates", _ ->
          batch =
            Agent.get_and_update(queue, fn
              [next | rest] -> {next, rest}
              [] -> {[], []}
            end)

          if batch == [], do: Process.sleep(20)
          {200, %{ok: true, result: batch}}

        "getMe", _ ->
          {200, %{ok: true, result: %{id: 99, username: "DungeonBot"}}}

        _, _ ->
          {200, %{ok: true, result: true}}
      end)

    Application.put_env(:dungeon, :api_base, base)
  end

  # A text message from alice, as Telegram would deliver it.
  defp update(id, chat, text) do
    %{
      update_id: id,
      message: %{text: text, chat: %{id: chat}, from: %{id: 1, username: "alice"}}
    }
  end

  test "registers commands, then answers each command", %{chat: chat} do
    fake_telegram([
      [update(10, chat, "/join"), update(11, chat, "hello")],
      [update(12, chat, "/party")]
    ])

    start_supervised!({Poller, "tok"})

    assert_receive {:telegram, "setMyCommands", %{"commands" => [_ | _]}}, 1_000
    assert_receive {:telegram, "sendMessage", %{"chat_id" => ^chat, "text" => joined}}, 1_000
    assert joined =~ "alice joins"
    assert_receive {:telegram, "sendMessage", %{"chat_id" => ^chat, "text" => party}}, 1_000
    assert party =~ "party of 1"

    # Plain chat ("hello") gets no reply.
    refute_receive {:telegram, "sendMessage", _}, 100
  end

  test "ignores commands addressed to another bot", %{chat: chat} do
    fake_telegram([[update(20, chat, "/help@OtherBot"), update(21, chat, "/help@DungeonBot")]])
    start_supervised!({Poller, "tok"})

    assert_receive {:telegram, "getMe", _}, 1_000
    assert_receive {:telegram, "sendMessage", %{"chat_id" => ^chat}}, 1_000
    # Only the command for this bot was answered.
    refute_receive {:telegram, "sendMessage", _}, 200
  end

  test "apologises when a command fails", %{chat: chat} do
    # The first chat id can't be stored in the database, so its command
    # fails the way it would if the database were down. The second chat
    # is unaffected.
    fake_telegram([[update(30, "not-a-chat", "/join"), update(31, chat, "/join")]])
    start_supervised!({Poller, "tok"})

    assert_receive {:telegram, "sendMessage", %{"chat_id" => "not-a-chat", "text" => sorry}},
                   2_000

    assert sorry =~ "Something went wrong"
    assert_receive {:telegram, "sendMessage", %{"chat_id" => ^chat, "text" => joined}}, 2_000
    assert joined =~ "alice joins"
  end

  test "acknowledges updates by advancing the offset", %{chat: chat} do
    fake_telegram([[update(41, chat, "/help"), update(42, chat, "/help")]])
    start_supervised!({Poller, "tok"})

    assert_receive {:telegram, "getUpdates", %{"offset" => 0}}, 1_000
    assert_receive {:telegram, "getUpdates", %{"offset" => 43}}, 1_000
  end

  test "logs a reply Telegram rejects, and carries on", %{chat: chat} do
    {:ok, queue} = Agent.start_link(fn -> [[update(50, chat, "/help")]] end)

    {_pid, base} =
      FakeTelegram.start(fn
        "getUpdates", _ ->
          batch =
            Agent.get_and_update(queue, fn
              [next | rest] -> {next, rest}
              [] -> {[], []}
            end)

          if batch == [], do: Process.sleep(20)
          {200, %{ok: true, result: batch}}

        "sendMessage", _ ->
          {403, %{ok: false, description: "Forbidden: bot was blocked by the user"}}

        _, _ ->
          {200, %{ok: true, result: true}}
      end)

    Application.put_env(:dungeon, :api_base, base)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = start_supervised!({Poller, "tok"})
        assert_receive {:telegram, "sendMessage", _}, 1_000
        # Telegram keeps being polled after the failure.
        assert_receive {:telegram, "getUpdates", %{"offset" => 51}}, 1_000
        assert Process.alive?(pid)
      end)

    assert log =~ "sendMessage to #{chat} failed"
  end

  test "keeps running when Telegram is unreachable" do
    # As in ClientTest: a port with nothing listening on it.
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    Application.put_env(:dungeon, :api_base, "http://127.0.0.1:#{port}")

    pid = start_supervised!({Poller, "tok"})
    Process.sleep(200)
    assert Process.alive?(pid)
  end
end
