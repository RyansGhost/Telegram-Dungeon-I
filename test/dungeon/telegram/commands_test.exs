defmodule Dungeon.Telegram.CommandsTest do
  use ExUnit.Case, async: true

  alias Dungeon.{GameServer, Store}
  alias Dungeon.Telegram.Commands

  setup do
    %{chat: System.unique_integer()}
  end

  defp send_text(text, chat, from \\ %{"id" => 1, "username" => "alice"}) do
    Commands.handle(%{
      "update_id" => 1,
      "message" => %{"text" => text, "chat" => %{"id" => chat}, "from" => from}
    })
  end

  defp reply(text, chat, from \\ %{"id" => 1, "username" => "alice"}) do
    {^chat, reply} = send_text(text, chat, from)
    reply
  end

  describe "parsing" do
    test "strips the bot mention used in groups and ignores case", %{chat: chat} do
      assert reply("/JOIN@DungeonBot", chat) =~ "alice joins"
    end

    test "ignores plain chat, unknown commands and non-message updates", %{chat: chat} do
      assert send_text("hello there", chat) == nil
      assert send_text("/dance", chat) == nil
      assert send_text("/", chat) == nil
      assert Commands.handle(%{"edited_message" => %{"text" => "/join"}}) == nil
      assert Commands.handle(%{"message" => %{"photo" => []}}) == nil
    end

    test "falls back from username to first name to id", %{chat: chat} do
      assert reply("/join", chat, %{"id" => 1, "first_name" => "Al"}) =~ "Al joins"
      assert reply("/join", chat, %{"id" => 2}) =~ "player2 joins"
    end
  end

  describe "help" do
    test "/start and /help list every menu command" do
      for cmd <- ["/start", "/help"] do
        {_, text} = send_text(cmd, 1)
        for %{command: c} <- Commands.menu(), do: assert(text =~ "/#{c}")
      end
    end

    test "the menu satisfies Telegram's setMyCommands limits" do
      for %{command: c, description: d} <- Commands.menu() do
        assert c =~ ~r/^[a-z0-9_]{1,32}$/
        assert String.length(d) in 1..256
      end
    end
  end

  describe "game commands" do
    test "movement shortcuts and /go", %{chat: chat} do
      reply("/join", chat)
      start = Store.load(chat).start_room
      [{dir, dest} | _] = Map.to_list(Store.load(chat).rooms[start].exits)

      assert reply("/#{String.first(dir)}", chat) =~ "heads #{dir}"
      assert Store.load(chat).players[1].room_id == dest

      back = %{"north" => "south", "south" => "north", "east" => "west", "west" => "east"}[dir]
      assert reply("/go #{back}", chat) =~ "heads #{back}"
      assert reply("/go", chat) =~ "Exits:"
    end

    test "multi-word arguments reach /use and /revive", %{chat: chat} do
      reply("/join", chat)
      assert reply("/use rusty key", chat) =~ "You don't have a rusty key"
      assert reply("/revive the bob", chat) =~ "no fallen adventurer"
    end

    test "each command reaches the engine", %{chat: chat} do
      reply("/join", chat)

      expectations = [
        {"/look", "Entrance"},
        {"/attack", "nothing here to fight"},
        {"/take", "nothing here to take"},
        {"/rest", "fully healed"},
        {"/descend", "no stairs"},
        {"/status", "alice — level 1"},
        {"/party", "party of 1"},
        {"/leave", "leaves the dungeon"}
      ]

      for {cmd, expected} <- expectations do
        assert reply(cmd, chat) =~ expected
      end
    end

    test "/newgame resets the chat's dungeon", %{chat: chat} do
      reply("/join", chat)
      old_seed = Store.load(chat).seed
      assert reply("/newgame", chat) =~ "new dungeon"
      assert Store.load(chat).players == %{}
      refute Store.load(chat).seed == old_seed
    end

    test "chats are isolated from each other", %{chat: chat} do
      other = System.unique_integer()
      reply("/join", chat)
      assert reply("/party", other) =~ "Nobody"
      assert GameServer.run(chat, &Dungeon.Engine.party/1) =~ "party of 1"
    end
  end
end
