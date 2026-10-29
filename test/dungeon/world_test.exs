# Floor generation. Layouts are random, so rather than checking specific
# floors, these tests check properties that must hold for every floor
# (connectivity, symmetric exits, one guarded stairwell, ...) across a
# spread of seeds and depths.
defmodule Dungeon.WorldTest do
  use ExUnit.Case, async: true

  alias Dungeon.{Monster, World}

  @opposite %{"north" => "south", "south" => "north", "east" => "west", "west" => "east"}
  @items ~w(potion whetstone elixir)

  # A spread of seeds and depths to check structural invariants against.
  @floors for seed <- [1, 7, 42, 1234, 99_999], depth <- 1..5, do: {seed, depth}

  test "the same seed and depth always produce the same floor" do
    for {seed, depth} <- @floors do
      assert World.generate(seed, depth) == World.generate(seed, depth)
    end
  end

  test "different depths or seeds produce different floors" do
    refute World.generate(42, 1) == World.generate(42, 2)
    refute World.generate(42, 1) == World.generate(43, 1)
  end

  test "floors grow with depth and honour an explicit size" do
    for {seed, depth} <- @floors do
      {rooms, _} = World.generate(seed, depth)
      assert map_size(rooms) == 8 + 2 * depth
    end

    {rooms, _} = World.generate(1, 1, 3)
    assert map_size(rooms) == 3
  end

  test "room ids match their keys and grid coordinates" do
    for {seed, depth} <- @floors, {id, room} <- elem(World.generate(seed, depth), 0) do
      assert room.id == id
      assert id =~ ~r/^-?\d+,-?\d+$/
    end
  end

  test "the entrance is at the origin and is safe" do
    for {seed, depth} <- @floors do
      {rooms, start} = World.generate(seed, depth)
      assert start == "0,0"
      assert %{name: "Entrance", monster: nil, items: [], stairs?: false} = rooms[start]
    end
  end

  test "there is exactly one stairwell, away from the entrance, always guarded" do
    for {seed, depth} <- @floors do
      {rooms, start} = World.generate(seed, depth)
      assert [stairs] = rooms |> Map.values() |> Enum.filter(& &1.stairs?)
      assert stairs.id != start
      assert stairs.name == "Stairwell"
      assert %Monster{} = stairs.monster
    end
  end

  test "exits connect adjacent rooms in both directions" do
    for {seed, depth} <- @floors do
      {rooms, _} = World.generate(seed, depth)

      for {id, room} <- rooms, {dir, dest} <- room.exits do
        assert Map.has_key?(rooms, dest)
        assert rooms[dest].exits[@opposite[dir]] == id
        assert adjacent?(id, dest, dir)
      end
    end
  end

  test "every room is reachable from the entrance" do
    for {seed, depth} <- @floors do
      {rooms, start} = World.generate(seed, depth)
      assert reachable(rooms, [start], MapSet.new()) == MapSet.new(Map.keys(rooms))
    end
  end

  test "loot is always a known item" do
    for {seed, depth} <- @floors, {_, room} <- elem(World.generate(seed, depth), 0) do
      assert Enum.all?(room.items, &(&1 in @items))
    end
  end

  describe "monster/2" do
    test "starts at full health" do
      {m, _} = World.monster(1, :rand.seed_s(:exsss, {1, 1, 1}))
      assert m.hp == m.max_hp
      assert m.hp > 0 and m.attack > 0
    end

    # Draw 300 monsters per depth and see which kinds turn up.
    test "deeper floors unlock tougher monsters" do
      names = fn depth ->
        Enum.reduce(1..300, {MapSet.new(), :rand.seed_s(:exsss, {depth, 2, 3})}, fn _,
                                                                                    {acc, rng} ->
          {m, rng} = World.monster(depth, rng)
          {MapSet.put(acc, m.name), rng}
        end)
        |> elem(0)
      end

      assert names.(1) == MapSet.new(["Giant Rat", "Goblin", "Skeleton"])
      assert MapSet.size(names.(4)) == 6
    end

    test "stats scale with depth" do
      strongest = fn depth ->
        Enum.reduce(1..300, {0, :rand.seed_s(:exsss, {9, 9, 9})}, fn _, {best, rng} ->
          {m, rng} = World.monster(depth, rng)
          {if(m.name == "Goblin", do: m.max_hp, else: best), rng}
        end)
        |> elem(0)
      end

      # Goblin: 9 HP at depth 1, 9 * 1.7 ≈ 15 at depth 3.
      assert strongest.(1) == 9
      assert strongest.(3) == 15
    end
  end

  # True if room `b` is one grid square from room `a` in direction `dir`.
  defp adjacent?(a, b, dir) do
    [ax, ay] = coords(a)
    [bx, by] = coords(b)

    case dir do
      "north" -> {bx, by} == {ax, ay + 1}
      "south" -> {bx, by} == {ax, ay - 1}
      "east" -> {bx, by} == {ax + 1, ay}
      "west" -> {bx, by} == {ax - 1, ay}
    end
  end

  defp coords(id), do: id |> String.split(",") |> Enum.map(&String.to_integer/1)

  # Depth-first search: every room id reachable from the ids in the list.
  defp reachable(_rooms, [], seen), do: seen

  defp reachable(rooms, [id | rest], seen) do
    if id in seen,
      do: reachable(rooms, rest, seen),
      else: reachable(rooms, Map.values(rooms[id].exits) ++ rest, MapSet.put(seen, id))
  end
end
