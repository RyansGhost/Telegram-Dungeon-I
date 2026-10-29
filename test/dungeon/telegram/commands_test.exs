# Command parsing and routing, from a raw Telegram update to the reply.
# These run the real GameServer and Store, so they check the whole path
# below the network layer.
defmodule Dungeon.Telegram.CommandsTest do
  use ExUnit.Case, async: true

  alias Dungeon.{GameServer, Store}
  alias Dungeon.Telegram.Commands

  setup do
    %{chat: System.unique_integer()}
  end

  # Feeds a text message to Commands.handle/1, shaped like a real update.
  defp send_text(text, chat, from \\ %{"id" => 1, "username" => "alice"}) do
    Commands.handle(%{
      "update_id" => 1,
      "message" => %{"text" => text, "chat" => %{"id" => chat}, "from" => from}
    })
  end

  # Like send_text/3, but asserts there was a reply to this chat and returns it.
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
      assert send_text("dance", chat) == nil
      assert send_text("/", chat) == nil
      assert Commands.handle(%{"edited_message" => %{"text" => "/join"}}) == nil
      assert Commands.handle(%{"message" => %{"photo" => []}}) == nil
    end

    test "commands and their arguments are case-insensitive", %{chat: chat} do
      reply("/Join", chat)
      assert reply("/LOOK", chat) =~ "📍 Entrance"
      start = Store.load(chat).start_room
      [{dir, _} | _] = Map.to_list(Store.load(chat).rooms[start].exits)
      assert reply("/GO #{String.upcase(dir)}", chat) =~ "heads #{dir}"
    end

    test "falls back from username to first name to id", %{chat: chat} do
      assert reply("/join", chat, %{"id" => 1, "first_name" => "Al"}) =~ "Al joins"
      assert reply("/join", chat, %{"id" => 2}) =~ "player2 joins"
    end
  end

  describe "without a slash" do
    test "a bare command works, in any case, with trailing punctuation", %{chat: chat} do
      assert reply("join", chat) =~ "alice joins"
      assert reply("Look", chat) =~ "📍 Entrance"
      assert reply("STATUS", chat) =~ "alice — level 1"
      assert reply("attack!", chat) =~ "nothing here to fight"
      assert reply("  party?  ", chat) =~ "party of 1"
      assert reply("help", chat) =~ "Dungeon commands"
    end

    test "movement: go plus a direction, or a direction alone", %{chat: chat} do
      reply("join", chat)
      start = Store.load(chat).start_room
      [{dir, dest} | _] = Map.to_list(Store.load(chat).rooms[start].exits)

      assert reply("Go #{String.capitalize(dir)}", chat) =~ "heads #{dir}"
      assert Store.load(chat).players[1].room_id == dest

      back = %{"north" => "south", "south" => "north", "east" => "west", "west" => "east"}[dir]
      assert reply(String.upcase(String.first(back)), chat) =~ "heads #{back}"
      assert Store.load(chat).players[1].room_id == start
    end

    test "use and revive take one word", %{chat: chat} do
      reply("join", chat)
      assert reply("use potion", chat) =~ "You don't have a potion"
      assert reply("revive bob", chat) =~ "no fallen adventurer"
    end

    test "ordinary chat is not mistaken for commands", %{chat: chat} do
      reply("join", chat)

      for text <- [
            "hello",
            "look at this!",
            "go home",
            "go north now",
            "attack the goblin please",
            "use the potion",
            "revive",
            "party time",
            "!!!",
            ""
          ] do
        assert send_text(text, chat) == nil, "#{inspect(text)} should be ignored"
      end
    end

    test "newgame needs its slash", %{chat: chat} do
      reply("join", chat)
      assert send_text("newgame", chat) == nil
      assert Store.load(chat).players |> Map.has_key?(1)
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
    # The dungeon here is randomly generated, so read its layout from the
    # store to know which way is open.
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
