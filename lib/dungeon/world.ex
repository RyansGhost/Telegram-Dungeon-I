defmodule Dungeon.World do
  @moduledoc """
  Procedural floor generation: a seeded random walk over a grid.

  The same `{seed, depth}` always produces the same floor, so a chat's
  dungeon can be regenerated deterministically.
  """

  alias Dungeon.{Monster, Room}

  @steps [{"north", {0, 1}}, {"south", {0, -1}}, {"east", {1, 0}}, {"west", {-1, 0}}]
  @opposite %{"north" => "south", "south" => "north", "east" => "west", "west" => "east"}

  @room_names [
    "Damp Cellar",
    "Collapsed Hall",
    "Fungal Grotto",
    "Bone Pit",
    "Flooded Crypt",
    "Shrine of Ash",
    "Rusted Armory",
    "Echoing Gallery",
    "Spider Den",
    "Forgotten Library",
    "Torture Chamber",
    "Crystal Cave",
    "Guard Post",
    "Sunken Chapel",
    "Rat Warren"
  ]
  @flavor [
    "Water drips steadily from the ceiling.",
    "The air smells of mould and old smoke.",
    "Scratches cover the walls, as if something tried to get out.",
    "A cold draft whistles through cracks in the stone.",
    "Faint whispers seem to come from nowhere in particular.",
    "Broken furniture is piled against one wall.",
    "Pale mushrooms glow softly in the corners."
  ]
  # {name, hp, attack, xp, gold} at depth 1; scaled by depth.
  @monsters [
    {"Giant Rat", 6, 2, 3, 1},
    {"Goblin", 9, 3, 5, 3},
    {"Skeleton", 12, 4, 7, 4},
    {"Cave Spider", 8, 5, 6, 2},
    {"Orc Brute", 18, 5, 12, 8},
    {"Wraith", 15, 7, 15, 10}
  ]
  @items ~w(potion potion potion whetstone elixir)

  @doc "Generates a floor. Returns `{rooms, start_room_id}`."
  def generate(seed, depth, size \\ nil) do
    size = size || 8 + 2 * depth
    rng = :rand.seed_s(:exsss, {seed, depth, 7919})

    {order, links, rng} = walk({0, 0}, [{0, 0}], MapSet.new([{0, 0}]), MapSet.new(), size, rng)

    {rooms, rng} =
      order
      |> Enum.with_index()
      |> Enum.map_reduce(rng, fn {pos, i}, rng -> build_room(pos, i, depth, rng) end)

    rooms = Enum.reduce(links, Map.new(rooms, &{&1.id, &1}), &connect/2)

    # Stairs go in the room farthest from the entrance, and are always guarded.
    far = Enum.max_by(tl(order), fn {x, y} -> abs(x) + abs(y) end)
    stairs = rooms[key(far)]
    {guard, _rng} = if stairs.monster, do: {stairs.monster, rng}, else: monster(depth, rng)

    stairs = %{
      stairs
      | name: "Stairwell",
        description: "A spiral staircase descends into darkness.",
        stairs?: true,
        monster: guard
    }

    start = %{
      rooms[key({0, 0})]
      | name: "Entrance",
        description: "Torchlight flickers at the mouth of the dungeon. A safe place to rest."
    }

    rooms = rooms |> Map.put(stairs.id, stairs) |> Map.put(start.id, start)
    {rooms, start.id}
  end

  @doc "Creates a monster scaled to `depth`."
  def monster(depth, rng) do
    pool = Enum.take(@monsters, 2 + depth)
    {{name, hp, atk, xp, gold}, rng} = pick(pool, rng)
    scale = 1 + 0.35 * (depth - 1)
    hp = round(hp * scale)

    monster = %Monster{
      name: name,
      hp: hp,
      max_hp: hp,
      attack: round(atk * scale),
      xp: round(xp * scale),
      gold: round(gold * scale)
    }

    {monster, rng}
  end

  defp walk(_pos, order, _visited, links, size, rng) when length(order) >= size,
    do: {Enum.reverse(order), links, rng}

  defp walk({x, y} = pos, order, visited, links, size, rng) do
    {{_dir, {dx, dy}}, rng} = pick(@steps, rng)
    next = {x + dx, y + dy}
    links = MapSet.put(links, {pos, next})

    if MapSet.member?(visited, next) do
      walk(next, order, visited, links, size, rng)
    else
      walk(next, [next | order], MapSet.put(visited, next), links, size, rng)
    end
  end

  defp build_room(pos, index, depth, rng) do
    {name, rng} = pick(@room_names, rng)
    {description, rng} = pick(@flavor, rng)
    {has_monster?, rng} = chance(0.6, rng)
    {has_item?, rng} = chance(0.3, rng)

    {monster, rng} =
      if index > 0 and has_monster?, do: monster(depth, rng), else: {nil, rng}

    {items, rng} =
      if index > 0 and has_item? do
        {item, rng} = pick(@items, rng)
        {[item], rng}
      else
        {[], rng}
      end

    room = %Room{
      id: key(pos),
      name: name,
      description: description,
      monster: monster,
      items: items
    }

    {room, rng}
  end

  defp connect({{ax, ay} = a, b}, rooms) do
    {dir, _} = Enum.find(@steps, fn {_, {dx, dy}} -> {ax + dx, ay + dy} == b end)

    rooms
    |> update_in([key(a), Access.key!(:exits)], &Map.put(&1, dir, key(b)))
    |> update_in([key(b), Access.key!(:exits)], &Map.put(&1, @opposite[dir], key(a)))
  end

  defp key({x, y}), do: "#{x},#{y}"

  defp pick(list, rng) do
    {i, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, i - 1), rng}
  end

  defp chance(p, rng) do
    {f, rng} = :rand.uniform_s(rng)
    {f < p, rng}
  end
end
