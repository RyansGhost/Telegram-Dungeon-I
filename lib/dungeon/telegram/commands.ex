defmodule Dungeon.Telegram.Commands do
  @moduledoc """
  Turns Telegram messages into game actions.

  handle/1 takes a raw update from `getUpdates` (decoded JSON) and, if it is
  a `/command` the bot knows, runs it against the chat's dungeon through
  `Dungeon.GameServer`. Anything else, such as ordinary chat in a group, is
  ignored.
  """

  alias Dungeon.{Engine, GameServer}

  # The commands shown in Telegram's `/` menu (registered at startup via
  # setMyCommands) and in /help. Telegram requires lowercase names of up to
  # 32 characters. The /n /s /e /w shortcuts work but are left off to keep
  # the menu short.
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

  # Built once, at compile time, from @menu.
  @help "🏰 Dungeon commands\n" <>
          Enum.map_join(@menu, "\n", fn {cmd, desc} -> "/#{cmd} — #{desc}" end) <>
          "\n\nAdd me to a group chat and everyone shares the same dungeon!"

  @doc "The command menu in the shape `setMyCommands` expects."
  def menu, do: Enum.map(@menu, fn {cmd, desc} -> %{command: cmd, description: desc} end)

  @doc "Returns `{chat_id, reply}` for a command message, or `nil` to ignore it."
  def handle(%{
        "message" => %{"text" => "/" <> text, "chat" => %{"id" => chat_id}, "from" => from}
      }) do
    # "/go north" -> command "go", args ["north"]. A bare "/" has no command
    # and falls through to `else`.
    with [command | args] <- String.split(text),
         # Group chats send "/go@MyDungeonBot north".
         command = command |> String.split("@") |> hd() |> String.downcase(),
         text when is_binary(text) <- reply(command, chat_id, from, args) do
      {chat_id, text}
    else
      _ -> nil
    end
  end

  # Not a text message starting with "/": photos, stickers, plain chat,
  # edits, and so on.
  def handle(_update), do: nil

  # Returns the reply text, or nil for an unknown command. Help and newgame
  # are handled here because they don't act on behalf of a player.
  defp reply(cmd, _chat_id, _from, _args) when cmd in ["start", "help"], do: @help
  defp reply("newgame", chat_id, _from, _args), do: GameServer.reset(chat_id)

  defp reply(cmd, chat_id, from, args) do
    case action(cmd, from["id"], display_name(from), args) do
      nil -> nil
      fun -> GameServer.run(chat_id, fun)
    end
  end

  # Maps a command to an Engine action, with the player's arguments filled in
  # so only the dungeon state is left to supply (`&1`). GameServer.run/2
  # calls it with the chat's current state.
  defp action("join", uid, name, _), do: &Engine.join(&1, uid, name)
  defp action("leave", uid, _, _), do: &Engine.leave(&1, uid)
  defp action("look", uid, _, _), do: &Engine.look(&1, uid)
  defp action("go", uid, _, args), do: &Engine.move(&1, uid, Enum.at(args, 0, ""))

  # Movement shortcuts: /n, /north, and so on.
  defp action(dir, uid, _, _) when dir in ~w(n s e w north south east west),
    do: &Engine.move(&1, uid, dir)

  defp action("attack", uid, _, _), do: &Engine.attack(&1, uid)
  defp action("take", uid, _, _), do: &Engine.take(&1, uid)
  # Arguments are re-joined so multi-word names work, e.g. "/revive Mary Jane".
  defp action("use", uid, _, args), do: &Engine.use_item(&1, uid, Enum.join(args, " "))
  defp action("revive", uid, _, args), do: &Engine.revive(&1, uid, Enum.join(args, " "))
  defp action("rest", uid, _, _), do: &Engine.rest(&1, uid)
  defp action("descend", uid, _, _), do: &Engine.descend(&1, uid)
  defp action("status", uid, _, _), do: &Engine.status(&1, uid)
  defp action("party", _, _, _), do: &Engine.party/1
  defp action(_, _, _, _), do: nil

  # The name players see: their @username if they have one, otherwise their
  # first name, otherwise a placeholder built from their user id.
  defp display_name(from), do: from["username"] || from["first_name"] || "player#{from["id"]}"
end
