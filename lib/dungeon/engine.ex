defmodule Dungeon.Engine do
  @moduledoc """
  Game rules as pure functions over a `Dungeon.State`. No Telegram, no I/O.

  Every action returns `{:ok, state, reply}` or `{:error, reply}`, where
  `reply` is the text to post back to the chat. An error means the action
  was not allowed (e.g. walking into a wall) and the state is unchanged.

  Actions take the acting player's Telegram `user_id`. Unless noted, the
  player must have joined and must not be down (at 0 HP).

  Combat and fleeing use the process's global `:rand` state, so outcomes
  vary from call to call; seed it with `:rand.seed/2` for repeatable
  results, as the tests do.
  """

  alias Dungeon.{Player, State, World}

  # Single-letter shorthands accepted by move/3.
  @aliases %{"n" => "north", "s" => "south", "e" => "east", "w" => "west"}

  @doc """
  Creates a fresh dungeon for `chat_id` at depth 1, with no players.

  A random seed is chosen unless one is given; the seed determines the
  layout of every floor of this dungeon.
  """
  def new(chat_id, seed \\ nil) do
    seed = seed || :rand.uniform(2_000_000_000)
    {rooms, start} = World.generate(seed, 1)
    %State{chat_id: chat_id, seed: seed, rooms: rooms, start_room: start}
  end

  @doc "Adds a new level 1 player called `name` at the entrance."
  def join(%State{} = d, user_id, name) do
    if Map.has_key?(d.players, user_id) do
      {:error, "#{name}, you're already in the dungeon."}
    else
      d = put_player(d, %Player{user_id: user_id, name: name, room_id: d.start_room})

      {:ok, d,
       "⚔️ #{name} joins the party at the dungeon entrance (depth #{d.depth}).\n\n" <>
         describe(d, user_id)}
    end
  end

  @doc "Removes the player from the dungeon for good. Allowed while down."
  def leave(d, user_id) do
    with {:ok, p} <- player(d, user_id, false) do
      {:ok, %{d | players: Map.delete(d.players, user_id)},
       "🚪 #{p.name} leaves the dungeon with #{p.gold} gold."}
    end
  end

  @doc "Describes the player's current room. Allowed while down."
  def look(d, user_id) do
    with {:ok, _p} <- player(d, user_id, false), do: {:ok, d, describe(d, user_id)}
  end

  @doc """
  Moves the player through the exit in `direction` (`"north"`, `"n"`, ...;
  any case).

  Leaving a room that still has a monster in it risks a parting blow (see
  flee/2 below). If that blow knocks the player out, they collapse where they
  stand and don't move.
  """
  def move(d, user_id, direction) do
    dir = String.downcase(direction)
    dir = Map.get(@aliases, dir, dir)

    with {:ok, p} <- player(d, user_id) do
      room = d.rooms[p.room_id]

      case Map.fetch(room.exits, dir) do
        :error ->
          {:error,
           "You can't go #{if dir == "", do: "nowhere", else: dir}. Exits: #{exits(room)}"}

        {:ok, dest} ->
          {p, prefix} = flee(p, room)

          if Player.down?(p) do
            {:ok, put_player(d, p), prefix}
          else
            d = put_player(d, %{p | room_id: dest})
            {:ok, d, prefix <> "#{p.name} heads #{dir}.\n\n" <> describe(d, user_id)}
          end
      end
    end
  end

  # Leaving a room with a living monster: 30% chance it hits the player for
  # 1..attack damage. Returns the updated player and text to put before the
  # move message (empty if nothing happened).
  defp flee(p, %{monster: nil}), do: {p, ""}

  defp flee(p, %{monster: m}) do
    if :rand.uniform() < 0.3 do
      dmg = :rand.uniform(m.attack)
      p = %{p | hp: max(0, p.hp - dmg)}

      if Player.down?(p),
        do: {p, "💀 The #{m.name} strikes #{p.name} for #{dmg} as they flee — they collapse!"},
        else: {p, "The #{m.name} hits #{p.name} for #{dmg} as they flee!\n\n"}
    else
      {p, ""}
    end
  end

  @doc """
  Attacks the monster in the player's room.

  The player deals `1..attack` damage plus their level. If the monster
  survives, it strikes back at one random living player in the room (not
  necessarily the attacker) for `1..monster.attack`.

  If the monster dies, its XP and gold are split evenly among every living
  player in the room (rounding down, but at least 1 XP each), which may
  level some of them up.
  """
  def attack(d, user_id) do
    with {:ok, p} <- player(d, user_id),
         room = d.rooms[p.room_id],
         {:ok, m} <- monster_in(room) do
      dmg = :rand.uniform(p.attack) + p.level
      m = %{m | hp: m.hp - dmg}
      hit = "🗡️ #{p.name} hits the #{m.name} for #{dmg}."
      # Everyone standing in the room shares the fight: the attacker first,
      # then any other living players here. Downed players sit it out.
      party = [p | Enum.reject(others_here(d, p), &Player.down?/1)]

      if m.hp <= 0 do
        # Monster slain: clear the room and pay out shares.
        n = length(party)
        xp = max(1, div(m.xp, n))
        gold = div(m.gold, n)

        {d, level_lines} =
          Enum.reduce(party, {put_room(d, %{room | monster: nil}), []}, fn member, {d, acc} ->
            {member, lines} = gain_xp(%{member | gold: member.gold + gold}, xp)
            {put_player(d, member), acc ++ lines}
          end)

        slain =
          "☠️ The #{m.name} is slain! Each of #{n} adventurer(s) gains #{xp} XP and #{gold} gold."

        {:ok, d, Enum.join([hit, slain | level_lines], "\n")}
      else
        # Monster survives: save its new HP and let it hit back.
        target = Enum.random(party)
        blow = :rand.uniform(m.attack)
        target = %{target | hp: max(0, target.hp - blow)}
        d = d |> put_room(%{room | monster: m}) |> put_player(target)

        lines = [
          hit,
          "The #{m.name} [#{m.hp}/#{m.max_hp}] strikes #{target.name} for #{blow}. " <>
            "(#{target.hp}/#{target.max_hp} HP)"
        ]

        lines =
          if Player.down?(target),
            do: lines ++ ["💀 #{target.name} collapses! Someone must /revive them."],
            else: lines

        {:ok, d, Enum.join(lines, "\n")}
      end
    end
  end

  # Adds XP, then applies as many level-ups as it pays for. Returns the
  # player and one announcement line per level gained.
  defp gain_xp(p, xp), do: level_up(%{p | xp: p.xp + xp}, [])

  # Reaching the next level costs `level * 20` XP (20 to reach level 2, 40 to
  # reach 3, ...). Leftover XP carries over. Each level adds 5 max HP and 1
  # attack, and heals the player fully.
  defp level_up(%Player{xp: xp, level: level} = p, acc) when xp >= level * 20 do
    max_hp = p.max_hp + 5

    p = %{
      p
      | xp: xp - level * 20,
        level: level + 1,
        max_hp: max_hp,
        hp: max_hp,
        attack: p.attack + 1
    }

    level_up(p, acc ++ ["🌟 #{p.name} reaches level #{p.level}!"])
  end

  defp level_up(p, acc), do: {p, acc}

  @doc """
  Picks up all loot in the player's room. Not allowed while a monster is
  still guarding it.
  """
  def take(d, user_id) do
    with {:ok, p} <- player(d, user_id) do
      room = d.rooms[p.room_id]

      cond do
        room.items == [] ->
          {:error, "There's nothing here to take."}

        room.monster ->
          {:error, "The #{room.monster.name} won't let you near the loot!"}

        true ->
          d =
            d
            |> put_room(%{room | items: []})
            |> put_player(%{p | inventory: p.inventory ++ room.items})

          {:ok, d, "🎒 #{p.name} picks up: #{Enum.join(room.items, ", ")}."}
      end
    end
  end

  @doc """
  Uses one copy of `item` from the player's inventory (name is trimmed and
  case-insensitive):

    * `potion` - heals up to 10 HP, never above max
    * `elixir` - +3 max HP, then heals fully
    * `whetstone` - +1 attack, permanently

  An item that isn't one of these stays in the inventory.
  """
  def use_item(d, user_id, item) do
    item = item |> String.trim() |> String.downcase()

    # `true <- cond || {:error, ...}` is a `with` idiom: when the condition
    # is false, the error tuple fails the match and is returned as-is.
    with {:ok, p} <- player(d, user_id),
         true <- item in p.inventory || {:error, "You don't have #{article(item)}."},
         {:ok, p, msg} <- apply_item(p, item) do
      {:ok, put_player(d, %{p | inventory: List.delete(p.inventory, item)}), msg}
    end
  end

  # Wording for "You don't have ...": a blank `/use` gets a friendlier phrase.
  defp article(""), do: "anything like that"
  defp article(item), do: "a #{item}"

  # Each item's effect. These return the updated player; use_item/3 removes
  # the item from the inventory only once its effect has applied.
  defp apply_item(p, "potion") do
    healed = min(10, p.max_hp - p.hp)
    p = %{p | hp: p.hp + healed}
    {:ok, p, "🧪 #{p.name} drinks a potion and recovers #{healed} HP (#{p.hp}/#{p.max_hp})."}
  end

  defp apply_item(p, "elixir") do
    p = %{p | max_hp: p.max_hp + 3, hp: p.max_hp + 3}
    {:ok, p, "⚗️ #{p.name} drinks an elixir: fully healed, max HP now #{p.max_hp}."}
  end

  defp apply_item(p, "whetstone") do
    p = %{p | attack: p.attack + 1}
    {:ok, p, "🔪 #{p.name} sharpens their blade. Attack is now #{p.attack}."}
  end

  defp apply_item(_p, item), do: {:error, "You can't use the #{item}."}

  @doc """
  Revives a downed player in the same room, bringing them back at half
  their max HP.

  `target_name` is matched case-insensitively against display names, with an
  optional leading `@` (so `/revive @Bob` works). Players can't revive
  themselves: being down blocks every action except look, status, party and
  leave.
  """
  def revive(d, user_id, target_name) do
    wanted = target_name |> String.trim() |> String.trim_leading("@") |> String.downcase()

    with {:ok, p} <- player(d, user_id) do
      case Enum.find(
             others_here(d, p),
             &(Player.down?(&1) and String.downcase(&1.name) == wanted)
           ) do
        nil ->
          {:error, "There's no fallen adventurer by that name here."}

        o ->
          o = %{o | hp: div(o.max_hp, 2)}
          {:ok, put_player(d, o), "✨ #{p.name} revives #{o.name} (#{o.hp}/#{o.max_hp} HP)."}
      end
    end
  end

  @doc "Heals the player to full HP. Only allowed at the entrance."
  def rest(d, user_id) do
    with {:ok, p} <- player(d, user_id) do
      if p.room_id == d.start_room do
        {:ok, put_player(d, %{p | hp: p.max_hp}),
         "🔥 #{p.name} rests by the torches and is fully healed."}
      else
        {:error, "You can only rest safely at the entrance."}
      end
    end
  end

  @doc """
  Takes the whole party down to the next floor. The player must be in the
  stairwell, and its guardian must be dead.

  Everyone is moved to the new floor's entrance, wherever they were standing,
  and anyone below half HP (including downed players) is patched up to
  half. The old floor is discarded.
  """
  def descend(d, user_id) do
    with {:ok, p} <- player(d, user_id) do
      room = d.rooms[p.room_id]

      cond do
        not room.stairs? ->
          {:error, "There are no stairs here."}

        room.monster ->
          {:error, "The #{room.monster.name} blocks the stairs!"}

        true ->
          # The whole party descends together; fallen members are carried along.
          depth = d.depth + 1
          {rooms, start} = World.generate(d.seed, depth)

          players =
            Map.new(d.players, fn {id, o} ->
              {id, %{o | room_id: start, hp: max(o.hp, div(o.max_hp, 2))}}
            end)

          d = %{d | depth: depth, rooms: rooms, start_room: start, players: players}

          {:ok, d,
           "🕳️ #{p.name} leads the party down to depth #{depth}!\n\n" <> describe(d, user_id)}
      end
    end
  end

  @doc "Shows the player's character sheet. Allowed while down."
  def status(d, user_id) do
    with {:ok, p} <- player(d, user_id, false) do
      pack = if p.inventory == [], do: "empty", else: Enum.join(p.inventory, ", ")

      {:ok, d,
       "🧙 #{p.name} — level #{p.level} (#{p.xp}/#{p.level * 20} XP)\n" <>
         "HP #{p.hp}/#{p.max_hp} · Attack #{p.attack} · Gold #{p.gold}\n" <>
         "Pack: #{pack}"}
    end
  end

  @doc """
  Lists everyone in the dungeon, highest level first (then by name), with
  their health and location. Needs no player, so anyone in the chat can ask.
  """
  def party(%State{players: players} = d) when map_size(players) == 0,
    do: {:ok, d, "Nobody is in the dungeon yet. Use /join to enter."}

  def party(d) do
    lines =
      d.players
      |> Map.values()
      |> Enum.sort_by(&{-&1.level, &1.name})
      |> Enum.map(fn p ->
        state = if Player.down?(p), do: "💀 down", else: "#{p.hp}/#{p.max_hp} HP"
        "• #{p.name} (lvl #{p.level}, #{state}) in #{d.rooms[p.room_id].name}"
      end)

    {:ok, d, Enum.join(["🏰 Depth #{d.depth} — party of #{map_size(d.players)}" | lines], "\n")}
  end

  ## Helpers

  # The room description shown by /look and after moving. Optional lines
  # evaluate to `false` or `nil` when they don't apply, and are filtered out
  # before joining.
  defp describe(d, user_id) do
    p = d.players[user_id]
    room = d.rooms[p.room_id]
    others = others_here(d, p)

    [
      "📍 #{room.name} (depth #{d.depth})",
      room.description,
      room.monster &&
        "👹 A #{room.monster.name} is here! [#{room.monster.hp}/#{room.monster.max_hp} HP]",
      room.items != [] && "✨ On the floor: #{Enum.join(room.items, ", ")}",
      others != [] &&
        "👥 Also here: " <>
          Enum.map_join(others, ", ", &"#{&1.name}#{if Player.down?(&1), do: " (down)"}"),
      room.stairs? && "🪜 Stairs lead down. Use /descend when the way is clear.",
      "Exits: #{exits(room)}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  # Exits as a sorted, comma-separated list, e.g. "east, north".
  defp exits(room), do: room.exits |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  # Looks up the acting player, with the standard error replies. Pass `false`
  # as `must_be_alive` for actions a downed player may still take.
  defp player(d, user_id, must_be_alive \\ true) do
    case Map.fetch(d.players, user_id) do
      :error ->
        {:error, "You haven't joined yet. Use /join to enter the dungeon."}

      {:ok, p} ->
        if must_be_alive and Player.down?(p),
          do: {:error, "#{p.name}, you are down! Another adventurer must /revive you."},
          else: {:ok, p}
    end
  end

  defp monster_in(%{monster: nil}), do: {:error, "There's nothing here to fight."}
  defp monster_in(%{monster: m}), do: {:ok, m}

  # Every other player in the same room as `p`, downed or not.
  defp others_here(d, p) do
    for {id, o} <- d.players, id != p.user_id, o.room_id == p.room_id, do: o
  end

  # Write an updated player or room back into the state.
  defp put_player(d, p), do: %{d | players: Map.put(d.players, p.user_id, p)}
  defp put_room(d, room), do: %{d | rooms: Map.put(d.rooms, room.id, room)}
end
