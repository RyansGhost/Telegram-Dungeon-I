defmodule Dungeon.WorldTest do
  use ExUnit.Case, async: true

  alias Dungeon.World

  test "generation is deterministic for a seed and depth" do
    assert World.generate(42, 1) == World.generate(42, 1)
    refute World.generate(42, 1) == World.generate(42, 2)
  end

  test "floor has the right size, a safe entrance and one guarded stairwell" do
    {rooms, start} = World.generate(7, 1)
    assert map_size(rooms) == 10
    assert rooms[start].name == "Entrance"
    assert rooms[start].monster == nil

    assert [stairs] = rooms |> Map.values() |> Enum.filter(& &1.stairs?)
    assert stairs.monster
  end

  test "exits are bidirectional and every room is reachable" do
    {rooms, start} = World.generate(123, 3)
    opposite = %{"north" => "south", "south" => "north", "east" => "west", "west" => "east"}

    for {id, room} <- rooms, {dir, dest} <- room.exits do
      assert rooms[dest].exits[opposite[dir]] == id
    end

    assert reachable(rooms, [start], MapSet.new()) == MapSet.new(Map.keys(rooms))
  end

  defp reachable(_rooms, [], seen), do: seen

  defp reachable(rooms, [id | rest], seen) do
    if id in seen,
      do: reachable(rooms, rest, seen),
      else: reachable(rooms, Map.values(rooms[id].exits) ++ rest, MapSet.put(seen, id))
  end
end
