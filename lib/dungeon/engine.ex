defmodule Dungeon.Engine do
  @moduledoc """
  Game rules as pure functions over a `Dungeon.State`. No Telegram, no I/O.

  Every action returns `{:ok, state, reply}` or `{:error, reply}`, where
  `reply` is the text to post back to the chat.
  """

  alias Dungeon.{Player, State, World}

  @aliases %{"n" => "north", "s" => "south", "e" => "east", "w" => "west"}

  def new(chat_id, seed \\ nil) do
    seed = seed || :rand.uniform(2_000_000_000)
    {rooms, start} = World.generate(seed, 1)
    %State{chat_id: chat_id, seed: seed, rooms: rooms, start_room: start}
  end

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

  def leave(d, user_id) do
    with {:ok, p} <- player(d, user_id, false) do
      {:ok, %{d | players: Map.delete(d.players, user_id)},
       "🚪 #{p.name} leaves the dungeon with #{p.gold} gold."}
    end
  end

  def look(d, user_id) do
    with {:ok, _p} <- player(d, user_id, false), do: {:ok, d, describe(d, user_id)}
  end

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

  # Leaving a room with a living monster risks a parting blow.
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

  def attack(d, user_id) do
    with {:ok, p} <- player(d, user_id),
         room = d.rooms[p.room_id],
         {:ok, m} <- monster_in(room) do
      dmg = :rand.uniform(p.attack) + p.level
      m = %{m | hp: m.hp - dmg}
      hit = "🗡️ #{p.name} hits the #{m.name} for #{dmg}."
      # Everyone standing in the room shares the fight.
      party = [p | Enum.reject(others_here(d, p), &Player.down?/1)]

      if m.hp <= 0 do
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

  defp gain_xp(p, xp), do: level_up(%{p | xp: p.xp + xp}, [])

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

  def use_item(d, user_id, item) do
    item = item |> String.trim() |> String.downcase()

    with {:ok, p} <- player(d, user_id),
         true <- item in p.inventory || {:error, "You don't have #{article(item)}."},
         {:ok, p, msg} <- apply_item(p, item) do
      {:ok, put_player(d, %{p | inventory: List.delete(p.inventory, item)}), msg}
    end
  end

  defp article(""), do: "anything like that"
  defp article(item), do: "a #{item}"

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

  def status(d, user_id) do
    with {:ok, p} <- player(d, user_id, false) do
      pack = if p.inventory == [], do: "empty", else: Enum.join(p.inventory, ", ")

      {:ok, d,
       "🧙 #{p.name} — level #{p.level} (#{p.xp}/#{p.level * 20} XP)\n" <>
         "HP #{p.hp}/#{p.max_hp} · Attack #{p.attack} · Gold #{p.gold}\n" <>
         "Pack: #{pack}"}
    end
  end

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

  defp exits(room), do: room.exits |> Map.keys() |> Enum.sort() |> Enum.join(", ")

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

  defp others_here(d, p) do
    for {id, o} <- d.players, id != p.user_id, o.room_id == p.room_id, do: o
  end

  defp put_player(d, p), do: %{d | players: Map.put(d.players, p.user_id, p)}
  defp put_room(d, room), do: %{d | rooms: Map.put(d.rooms, room.id, room)}
end
