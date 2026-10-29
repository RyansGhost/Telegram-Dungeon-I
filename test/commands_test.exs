defmodule Dungeon.Telegram.CommandsTest do
  use ExUnit.Case

  alias Dungeon.Telegram.Commands

  defp msg(text, chat_id, user_id, name) do
    %{
      "update_id" => 1,
      "message" => %{
        "text" => text,
        "chat" => %{"id" => chat_id},
        "from" => %{"id" => user_id, "username" => name}
      }
    }
  end

  test "a full round trip through the game server and store" do
    chat = System.unique_integer([:positive])
    assert {^chat, _} = Commands.handle(msg("/newgame", chat, 1, "alice"))
    assert {^chat, joined} = Commands.handle(msg("/join@DungeonBot", chat, 1, "alice"))
    assert joined =~ "alice joins"
    assert {^chat, _} = Commands.handle(msg("/join", chat, 2, "bob"))
    assert {^chat, party} = Commands.handle(msg("/party", chat, 1, "alice"))
    assert party =~ "party of 2"

    assert Dungeon.Store.load(chat).players |> map_size() == 2
  end

  test "non-commands and unknown commands are ignored" do
    assert Commands.handle(msg("hello", 1, 1, "a")) == nil
    assert Commands.handle(msg("/dance", 1, 1, "a")) == nil
    assert Commands.handle(%{"edited_message" => %{}}) == nil
  end
end
