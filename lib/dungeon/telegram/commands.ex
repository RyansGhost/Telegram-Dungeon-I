defmodule Dungeon.Telegram.Commands do
  @moduledoc """
  Turns Telegram messages into game actions.

  handle/1 takes a raw update from `getUpdates` (decoded JSON) and, if it is
  a command the bot knows, runs it against the chat's dungeon through
  `Dungeon.GameServer`. Anything else, such as ordinary chat in a group, is
  ignored.

  Commands are case-insensitive, and the slash is optional: `/look`,
  `/LOOK`, `look` and `Look!` all work. Without a slash, though, a message
  only counts as a command if it has exactly the shape of one (see
  bare_command?/2), so everyday chat like "look at this" or "go team" isn't
  mistaken for a game move. `/newgame` always needs its slash, so a stray
  word can't wipe a chat's dungeon.
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
          "\n\nThe slash is optional: just type look, go north, attack…" <>
          "\nAdd me to a group chat and everyone shares the same dungeon!"

  # Directions, for /go and the movement shortcuts.
  @directions ~w(n s e w north south east west)

  # Commands that take no arguments. Without a slash, they must be the whole
  # message ("look", not "look at this").
  @no_args ~w(start help join leave look attack take rest descend status party) ++ @directions

  @doc "The command menu in the shape `setMyCommands` expects."
  def menu, do: Enum.map(@menu, fn {cmd, desc} -> %{command: cmd, description: desc} end)

  @doc "Returns `{chat_id, reply}` for a command message, or `nil` to ignore it."
  def handle(%{"message" => %{"text" => text, "chat" => %{"id" => chat_id}, "from" => from}})
      when is_binary(text) do
    with {:ok, command, args} <- parse(String.trim(text)),
         reply when is_binary(reply) <- reply(command, chat_id, from, args) do
      {chat_id, reply}
    else
      _ -> nil
    end
  end

  # Not a text message: photos, stickers, edits, and so on.
  def handle(_update), do: nil

  # Splits a message into a lowercased command name and its arguments, e.g.
  # "/Go North" -> {:ok, "go", ["North"]}, or returns :ignore. Arguments keep
  # their case; the engine matches directions, items and names
  # case-insensitively.
  #
  # With a slash, any word is taken as a command (unknown ones are ignored
  # later). A bare "/" has no command.
  defp parse("/" <> text) do
    case String.split(text) do
      [command | args] -> {:ok, command_name(command), args}
      [] -> :ignore
    end
  end

  # Without a slash, trailing punctuation is dropped ("Attack!" -> "attack"),
  # and the message must pass bare_command?/2.
  defp parse(text) do
    with [command | args] <- text |> String.replace(~r/[.!?]+$/u, "") |> String.split(),
         command = command_name(command),
         true <- bare_command?(command, args) do
      {:ok, command, args}
    else
      _ -> :ignore
    end
  end

  # Lowercases a command and drops a bot mention: group chats send
  # "/go@MyDungeonBot north" when someone picks from the command menu.
  defp command_name(word), do: word |> String.split("@") |> hd() |> String.downcase()

  # Whether a message without a slash has exactly the shape of a command:
  # a no-argument command on its own, "go" plus one direction, or "use" /
  # "revive" plus one word (an item or a player's name).
  defp bare_command?(command, []) when command in @no_args, do: true
  defp bare_command?("go", [dir]), do: String.downcase(dir) in @directions
  defp bare_command?(command, [_one]) when command in ["use", "revive"], do: true
  defp bare_command?(_command, _args), do: false

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
  defp action(dir, uid, _, _) when dir in @directions,
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
