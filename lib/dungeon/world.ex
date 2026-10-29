defmodule Dungeon.World do
  @moduledoc """
  Procedural floor generation: a seeded random walk over a grid.

  A floor is built in four steps:

    1. **Walk.** Starting at `{0, 0}`, take random one-square steps
       north/south/east/west until enough distinct squares have been visited.
       Each square becomes a room, and each step taken becomes a passage, so
       the floor is always fully connected (you can walk back along any path
       the generator walked).
    2. **Furnish.** Give each room a random name and description, and, except
       for the entrance, a chance of a monster and of loot.
    3. **Connect.** Turn every step into a pair of exits, one in each
       direction.
    4. **Mark.** The room farthest from the entrance becomes the stairwell
       (always guarded by a monster); the origin becomes the safe entrance.

  The same `{seed, depth}` always produces the same floor, so a chat's
  dungeon can be regenerated deterministically. To make that work, all
  randomness flows through an explicit random-number state (`rng`) that each
  helper takes and returns, rather than the process-global `:rand` state used
  during play.
  """

  alias Dungeon.{Monster, Room}

  # Directions and the grid offset each one moves by: north is +y, east is +x.
  @steps [{"north", {0, 1}}, {"south", {0, -1}}, {"east", {1, 0}}, {"west", {-1, 0}}]
  @opposite %{"north" => "south", "south" => "north", "east" => "west", "west" => "east"}

  # Cosmetic text, picked at random for each room.
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
  # {name, hp, attack, xp, gold} at depth 1, ordered weakest to strongest;
  # stats are scaled up by depth in monster/2.
  @monsters [
    {"Giant Rat", 6, 2, 3, 1},
    {"Goblin", 9, 3, 5, 3},
    {"Skeleton", 12, 4, 7, 4},
    {"Cave Spider", 8, 5, 6, 2},
    {"Orc Brute", 18, 5, 12, 8},
    {"Wraith", 15, 7, 15, 10}
  ]
  # Loot table. Repeats act as weights: potions are three times as common.
  @items ~w(potion potion potion whetstone elixir)

  @doc """
  Generates the floor at `depth` for a dungeon's `seed`.

  Floors grow by two rooms per depth (10 rooms at depth 1); pass `size` to
  override that. Returns `{rooms, start_room_id}`, where `rooms` maps room id
  to `Dungeon.Room`.
  """
  def generate(seed, depth, size \\ nil) do
    size = size || 8 + 2 * depth
    # Seed a private generator from {seed, depth}. The constant third element
    # is arbitrary; :exsss just needs three integers.
    rng = :rand.seed_s(:exsss, {seed, depth, 7919})

    # 1. Walk: `order` is the visited squares in first-visit order (the origin
    # first), and `links` is every step taken, as {from, to} pairs.
    {order, links, rng} = walk({0, 0}, [{0, 0}], MapSet.new([{0, 0}]), MapSet.new(), size, rng)

    # 2. Furnish: build a room per square. The index tells build_room/4 which
    # square is the entrance (index 0), which must stay empty.
    {rooms, rng} =
      order
      |> Enum.with_index()
      |> Enum.map_reduce(rng, fn {pos, i}, rng -> build_room(pos, i, depth, rng) end)

    # 3. Connect: turn each step into exits on both rooms.
    rooms = Enum.reduce(links, Map.new(rooms, &{&1.id, &1}), &connect/2)

    # 4. Mark: stairs go in the room farthest from the entrance (by grid
    # distance), and are always guarded. Ties go to the first room visited.
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

  @doc """
  Creates a random monster scaled to `depth`, using (and returning) the
  random state `rng`.

  Depth 1 draws from the three weakest monsters, and each floor deeper adds
  the next one to the pool. Stats grow linearly, by 35% of their base value
  per floor below the first (so depth 3 monsters are 1.7x as strong).
  Returns `{monster, rng}`.
  """
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

  # The random walk. `order` is built in reverse (newest square first) and
  # flipped once at the end; `visited` mirrors it as a set for fast lookups.
  # Stepping onto an already-visited square still records the step, which
  # adds a passage between existing rooms and can create loops.
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

  # Builds the room at grid position `pos`. Rooms other than the entrance
  # (index 0) get a 60% chance of a monster and a 30% chance of one item.
  # (The entrance still makes both coin flips, but ignores the results.)
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

  # Adds the exits for one step `a -> b`: work out which direction leads from
  # a to b, then add that exit to a and the opposite exit to b.
  defp connect({{ax, ay} = a, b}, rooms) do
    {dir, _} = Enum.find(@steps, fn {_, {dx, dy}} -> {ax + dx, ay + dy} == b end)

    rooms
    |> update_in([key(a), Access.key!(:exits)], &Map.put(&1, dir, key(b)))
    |> update_in([key(b), Access.key!(:exits)], &Map.put(&1, @opposite[dir], key(a)))
  end

  # Room id for a grid position, e.g. {-1, 2} -> "-1,2".
  defp key({x, y}), do: "#{x},#{y}"

  # Picks a uniformly random element of `list`. Returns {element, rng}.
  defp pick(list, rng) do
    {i, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, i - 1), rng}
  end

  # True with probability `p` (0.0..1.0). Returns {boolean, rng}.
  defp chance(p, rng) do
    {f, rng} = :rand.uniform_s(rng)
    {f < p, rng}
  end
end
