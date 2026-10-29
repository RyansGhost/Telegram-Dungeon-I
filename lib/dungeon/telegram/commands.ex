defmodule Dungeon.Telegram.Commands do
  @moduledoc "Turns Telegram messages into game actions."

  alias Dungeon.{Engine, GameServer}

  @menu [
    {"join", "Enter this chat's dungeon"},
    {"look", "Describe your surroundings"},
    {"go", "Move: /go north (or /n /s /e /w)"},
    {"attack", "Fight the monster in your room"},
    {"take", "Pick up loot"},
    {"use", "Use an item: /use potion"},
    {"revive", "Revive a fallen ally: /revive name"},
    {"rest", "Heal fully at the entrance"},
    {"descend", "Take the party down the stairs"},
    {"status", "Your character sheet"},
    {"party", "Everyone in the dungeon"},
    {"leave", "Leave the dungeon"},
    {"newgame", "Reset this chat's dungeon"},
    {"help", "Show commands"}
  ]

  @help "🏰 Dungeon commands\n" <>
          Enum.map_join(@menu, "\n", fn {cmd, desc} -> "/#{cmd} — #{desc}" end) <>
          "\n\nAdd me to a group chat and everyone shares the same dungeon!"

  def menu, do: Enum.map(@menu, fn {cmd, desc} -> %{command: cmd, description: desc} end)

  @doc "Returns `{chat_id, reply}` for a command message, or `nil` to ignore it."
  def handle(%{
        "message" => %{"text" => "/" <> text, "chat" => %{"id" => chat_id}, "from" => from}
      }) do
    [command | args] = String.split(text)
    # Group chats send "/go@MyDungeonBot north".
    command = command |> String.split("@") |> hd() |> String.downcase()

    case reply(command, chat_id, from, args) do
      nil -> nil
      text -> {chat_id, text}
    end
  end

  def handle(_update), do: nil

  defp reply(cmd, _chat_id, _from, _args) when cmd in ["start", "help"], do: @help
  defp reply("newgame", chat_id, _from, _args), do: GameServer.reset(chat_id)

  defp reply(cmd, chat_id, from, args) do
    case action(cmd, from["id"], display_name(from), args) do
      nil -> nil
      fun -> GameServer.run(chat_id, fun)
    end
  end

  defp action("join", uid, name, _), do: &Engine.join(&1, uid, name)
  defp action("leave", uid, _, _), do: &Engine.leave(&1, uid)
  defp action("look", uid, _, _), do: &Engine.look(&1, uid)
  defp action("go", uid, _, args), do: &Engine.move(&1, uid, Enum.at(args, 0, ""))

  defp action(dir, uid, _, _) when dir in ~w(n s e w north south east west),
    do: &Engine.move(&1, uid, dir)

  defp action("attack", uid, _, _), do: &Engine.attack(&1, uid)
  defp action("take", uid, _, _), do: &Engine.take(&1, uid)
  defp action("use", uid, _, args), do: &Engine.use_item(&1, uid, Enum.join(args, " "))
  defp action("revive", uid, _, args), do: &Engine.revive(&1, uid, Enum.join(args, " "))
  defp action("rest", uid, _, _), do: &Engine.rest(&1, uid)
  defp action("descend", uid, _, _), do: &Engine.descend(&1, uid)
  defp action("status", uid, _, _), do: &Engine.status(&1, uid)
  defp action("party", _, _, _), do: &Engine.party/1
  defp action(_, _, _, _), do: nil

  defp display_name(from), do: from["username"] || from["first_name"] || "player#{from["id"]}"
end
