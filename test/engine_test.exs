defmodule Dungeon.EngineTest do
  use ExUnit.Case, async: true

  alias Dungeon.{Engine, Monster}

  setup do
    :rand.seed(:exsss, {1, 2, 3})
    {:ok, d, _} = Engine.join(Engine.new(-100, 99), 1, "alice")
    {:ok, d, _} = Engine.join(d, 2, "bob")
    %{d: d}
  end

  defp put_monster(d, room_id, monster) do
    put_in(d.rooms[room_id].monster, monster)
  end

  defp weak_monster, do: %Monster{name: "Rat", hp: 1, max_hp: 1, attack: 1, xp: 10, gold: 4}

  test "players must join before acting", %{d: d} do
    assert {:error, msg} = Engine.look(d, 3)
    assert msg =~ "/join"
    assert {:error, _} = Engine.join(d, 1, "alice")
  end

  test "players see each other in the same room", %{d: d} do
    assert {:ok, _, text} = Engine.look(d, 1)
    assert text =~ "Also here: bob"
  end

  test "moving follows exits and rejects walls", %{d: d} do
    [{dir, dest} | _] = Map.to_list(d.rooms[d.start_room].exits)
    assert {:ok, d2, _} = Engine.move(d, 1, String.first(dir))
    assert d2.players[1].room_id == dest

    blocked =
      Enum.find(~w(north south east west), &(not Map.has_key?(d.rooms[d.start_room].exits, &1)))

    if blocked, do: assert({:error, _} = Engine.move(d, 1, blocked))
  end

  test "killing a monster splits rewards among the party in the room", %{d: d} do
    d = put_monster(d, d.start_room, weak_monster())
    assert {:ok, d, text} = Engine.attack(d, 1)
    assert text =~ "slain"
    assert d.rooms[d.start_room].monster == nil
    assert d.players[1].gold == 2 and d.players[2].gold == 2
    assert d.players[1].xp == 5 and d.players[2].xp == 5
  end

  test "downed players can't act until revived", %{d: d} do
    d = put_in(d.players[2].hp, 0)
    assert {:error, msg} = Engine.attack(d, 2)
    assert msg =~ "revive"

    assert {:ok, d, _} = Engine.revive(d, 1, "@Bob")
    assert d.players[2].hp == 10
  end

  test "loot and items", %{d: d} do
    d = put_in(d.rooms[d.start_room].items, ["potion"])
    assert {:ok, d, _} = Engine.take(d, 1)
    assert d.players[1].inventory == ["potion"]

    d = put_in(d.players[1].hp, 5)
    assert {:ok, d, _} = Engine.use_item(d, 1, "Potion")
    assert d.players[1].hp == 15
    assert d.players[1].inventory == []
    assert {:error, _} = Engine.use_item(d, 1, "potion")
  end

  test "levelling up raises stats", %{d: d} do
    d = put_monster(d, d.start_room, %{weak_monster() | xp: 50})
    {:ok, d, text} = Engine.attack(d, 1)
    assert text =~ "reaches level 2"
    assert d.players[1].level == 2
    assert d.players[1].max_hp == 25
  end

  test "the party descends together once the stairs are clear", %{d: d} do
    {stairs_id, _} = Enum.find(d.rooms, fn {_, r} -> r.stairs? end)
    d = put_in(d.players[1].room_id, stairs_id)
    assert {:error, _} = Engine.descend(d, 1)

    d = put_monster(d, stairs_id, nil)
    assert {:ok, d, text} = Engine.descend(d, 1)
    assert text =~ "depth 2"
    assert d.depth == 2
    assert Enum.all?(Map.values(d.players), &(&1.room_id == d.start_room))
  end
end
