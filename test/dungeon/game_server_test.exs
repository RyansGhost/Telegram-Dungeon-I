# The per-chat game process: starting on demand, saving changes,
# serializing commands, and stopping when idle. Each test uses its own chat
# id, so each gets its own server and saved state.
defmodule Dungeon.GameServerTest do
  use ExUnit.Case, async: true

  alias Dungeon.{Engine, GameServer, Store}

  setup do
    %{chat: System.unique_integer()}
  end

  # The pid of the chat's running server.
  defp server(chat) do
    [{pid, _}] = Registry.lookup(Dungeon.Registry, chat)
    pid
  end

  test "starts a fresh dungeon for a new chat", %{chat: chat} do
    assert GameServer.run(chat, &Engine.party/1) =~ "Nobody is in the dungeon"
  end

  test "persists successful changes", %{chat: chat} do
    assert GameServer.run(chat, &Engine.join(&1, 1, "alice")) =~ "alice joins"
    assert Map.has_key?(Store.load(chat).players, 1)
  end

  test "does not persist read-only actions or errors", %{chat: chat} do
    GameServer.run(chat, &Engine.party/1)
    assert Store.load(chat) == nil

    assert GameServer.run(chat, &Engine.attack(&1, 1)) =~ "/join"
    assert Store.load(chat) == nil
  end

  test "keeps one server per chat", %{chat: chat} do
    GameServer.run(chat, &Engine.party/1)
    pid = server(chat)
    GameServer.run(chat, &Engine.party/1)
    assert server(chat) == pid
  end

  test "serializes concurrent commands so none are lost", %{chat: chat} do
    1..50
    |> Enum.map(fn id ->
      Task.async(fn -> GameServer.run(chat, &Engine.join(&1, id, "p#{id}")) end)
    end)
    |> Task.await_many()

    assert map_size(Store.load(chat).players) == 50
  end

  test "stops when idle and resumes from the store", %{chat: chat} do
    GameServer.run(chat, &Engine.join(&1, 1, "alice"))
    pid = server(chat)
    ref = Process.monitor(pid)

    # Simulate 30 idle minutes by delivering the timeout message directly.
    send(pid, :timeout)
    assert_receive {:DOWN, ^ref, _, _, :normal}

    assert GameServer.run(chat, &Engine.party/1) =~ "alice"
    refute server(chat) == pid
  end

  test "reset replaces the dungeon", %{chat: chat} do
    GameServer.run(chat, &Engine.join(&1, 1, "alice"))
    assert GameServer.reset(chat) =~ "new dungeon"
    assert Store.load(chat).players == %{}
  end
end
