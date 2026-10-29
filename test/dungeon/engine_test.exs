defmodule Dungeon.EngineTest do
  use ExUnit.Case, async: true

  import Dungeon.Fixtures

  alias Dungeon.{Engine, Player}

  setup do
    :rand.seed(:exsss, {1, 2, 3})
    :ok
  end

  describe "new/2" do
    test "creates a floor at depth 1 with the given seed" do
      d = Engine.new(7, 1234)
      assert d.chat_id == 7
      assert d.seed == 1234
      assert d.depth == 1
      assert d.players == %{}
      assert d.rooms[d.start_room].name == "Entrance"
    end

    test "is deterministic for a seed and random without one" do
      assert Engine.new(1, 99).rooms == Engine.new(1, 99).rooms
      refute Engine.new(1).seed == Engine.new(1).seed
    end
  end

  describe "join/3" do
    test "places a new player at the entrance and describes it" do
      assert {:ok, d, text} = Engine.join(state(), 1, "alice")
      assert %Player{name: "alice", room_id: "a", hp: 20, level: 1} = d.players[1]
      assert text =~ "alice joins the party"
      assert text =~ "📍 Entrance"
    end

    test "rejects joining twice" do
      {:ok, d, _} = Engine.join(state(), 1, "alice")
      assert {:error, msg} = Engine.join(d, 1, "alice")
      assert msg =~ "already in the dungeon"
    end
  end

  describe "leave/2" do
    test "removes the player and reports their gold" do
      d = add(state(), player(1, "alice", gold: 12))
      assert {:ok, d, text} = Engine.leave(d, 1)
      assert d.players == %{}
      assert text =~ "12 gold"
    end

    test "works even while downed" do
      d = add(state(), player(1, "alice", hp: 0))
      assert {:ok, _, _} = Engine.leave(d, 1)
    end

    test "requires having joined" do
      assert {:error, msg} = Engine.leave(state(), 1)
      assert msg =~ "/join"
    end
  end

  describe "look/2" do
    test "lists monsters, loot, other players, stairs and exits" do
      d =
        state()
        |> add([player(1, "alice", room_id: "c"), player(2, "bob", room_id: "c", hp: 0)])
        |> put_monster("c", monster(name: "Ogre", hp: 3, max_hp: 9))
        |> put_items("c", ["potion", "elixir"])

      assert {:ok, ^d, text} = Engine.look(d, 1)
      assert text =~ "📍 Stairwell (depth 1)"
      assert text =~ "A Ogre is here! [3/9 HP]"
      assert text =~ "On the floor: potion, elixir"
      assert text =~ "Also here: bob (down)"
      assert text =~ "/descend"
      assert text =~ "Exits: west"
    end

    test "omits empty sections and sorts exits" do
      {:ok, _, text} = state() |> add(player(1, "alice", room_id: "b")) |> Engine.look(1)
      refute text =~ "is here!"
      refute text =~ "On the floor"
      refute text =~ "Also here"
      refute text =~ "Stairs"
      assert text =~ "Exits: east, north, west"
    end

    test "doesn't show players in other rooms" do
      d = add(state(), [player(1, "alice"), player(2, "bob", room_id: "b")])
      {:ok, _, text} = Engine.look(d, 1)
      refute text =~ "bob"
    end

    test "is allowed while downed" do
      d = add(state(), player(1, "alice", hp: 0))
      assert {:ok, _, _} = Engine.look(d, 1)
    end
  end

  describe "move/3" do
    setup do
      %{d: add(state(), player(1, "alice"))}
    end

    test "follows an exit", %{d: d} do
      assert {:ok, d, text} = Engine.move(d, 1, "east")
      assert d.players[1].room_id == "b"
      assert text =~ "alice heads east"
      assert text =~ "📍 Hall"
    end

    test "accepts single-letter aliases and any case", %{d: d} do
      assert {:ok, d, _} = Engine.move(d, 1, "E")
      assert {:ok, d, _} = Engine.move(d, 1, "n")
      assert d.players[1].room_id == "d"
      assert {:ok, d, _} = Engine.move(d, 1, "SOUTH")
      assert d.players[1].room_id == "b"
    end

    test "rejects walls and lists the exits", %{d: d} do
      assert {:error, msg} = Engine.move(d, 1, "north")
      assert msg =~ "can't go north"
      assert msg =~ "Exits: east"
    end

    test "rejects a missing direction", %{d: d} do
      assert {:error, msg} = Engine.move(d, 1, "")
      assert msg =~ "Exits: east"
    end

    test "downed players can't move" do
      d = add(state(), player(1, "alice", hp: 0))
      assert {:error, msg} = Engine.move(d, 1, "east")
      assert msg =~ "/revive"
    end

    test "fleeing a monster sometimes costs HP but never more than its attack" do
      d =
        state()
        |> add(player(1, "alice", room_id: "b"))
        |> put_monster("b", monster(attack: 3))

      outcomes =
        for seed <- 1..200 do
          :rand.seed(:exsss, {seed, 0, 0})
          {:ok, d2, text} = Engine.move(d, 1, "west")
          lost = 20 - d2.players[1].hp
          assert lost in 0..3
          assert d2.players[1].room_id == "a"
          if lost > 0, do: assert(text =~ "as they flee")
          lost > 0
        end

      assert true in outcomes, "expected at least one parting blow"
      assert false in outcomes, "expected at least one clean escape"
    end

    test "a parting blow can knock a player out, leaving them in the room" do
      d =
        state()
        |> add(player(1, "alice", room_id: "b", hp: 1))
        |> put_monster("b", monster(attack: 1))

      {d2, text} =
        Enum.find_value(1..200, fn seed ->
          :rand.seed(:exsss, {seed, 0, 0})
          {:ok, d2, text} = Engine.move(d, 1, "west")
          if Player.down?(d2.players[1]), do: {d2, text}
        end)

      assert d2.players[1].room_id == "b"
      assert text =~ "collapse"
    end
  end

  describe "attack/2" do
    test "needs a monster" do
      d = add(state(), player(1, "alice"))
      assert {:error, msg} = Engine.attack(d, 1)
      assert msg =~ "nothing here to fight"
    end

    test "downed players can't attack" do
      d = state() |> add(player(1, "alice", hp: 0)) |> put_monster("a", monster())
      assert {:error, _} = Engine.attack(d, 1)
    end

    test "deals 1..attack plus level damage and takes a counterattack" do
      d =
        state()
        |> add(player(1, "alice", attack: 1, level: 2))
        |> put_monster("a", monster(hp: 10, max_hp: 10, attack: 1))

      assert {:ok, d, text} = Engine.attack(d, 1)
      assert d.rooms["a"].monster.hp == 7
      assert d.players[1].hp == 19
      assert text =~ "alice hits the Rat for 3"
      assert text =~ "Rat [7/10] strikes alice for 1. (19/20 HP)"
    end

    test "counterattacks only hit living players in the same room" do
      d =
        state()
        |> add([
          player(1, "alice", attack: 1),
          player(2, "bob"),
          player(3, "carol", hp: 0),
          player(4, "dave", room_id: "b")
        ])
        |> put_monster("a", monster(hp: 1000, max_hp: 1000, attack: 2))

      hit =
        Enum.reduce(1..100, MapSet.new(), fn _, acc ->
          {:ok, d2, _} = Engine.attack(d, 1)
          [hurt] = for {id, p} <- d2.players, p.hp != d.players[id].hp, do: id
          MapSet.put(acc, hurt)
        end)

      assert hit == MapSet.new([1, 2])
    end

    test "announces when the counterattack downs someone" do
      d =
        state()
        |> add(player(1, "alice", attack: 1, hp: 1))
        |> put_monster("a", monster(hp: 100, attack: 1))

      assert {:ok, d, text} = Engine.attack(d, 1)
      assert Player.down?(d.players[1])
      assert text =~ "alice collapses"
    end

    test "killing a monster clears it and splits rewards among the living party in the room" do
      d =
        state()
        |> add([
          player(1, "alice"),
          player(2, "bob"),
          player(3, "carol", hp: 0),
          player(4, "dave", room_id: "b")
        ])
        |> put_monster("a", monster(hp: 1, xp: 11, gold: 5))

      assert {:ok, d, text} = Engine.attack(d, 1)
      assert d.rooms["a"].monster == nil
      assert text =~ "Rat is slain! Each of 2 adventurer(s) gains 5 XP and 2 gold"

      assert {d.players[1].xp, d.players[1].gold} == {5, 2}
      assert {d.players[2].xp, d.players[2].gold} == {5, 2}
      assert {d.players[3].xp, d.players[3].gold} == {0, 0}
      assert {d.players[4].xp, d.players[4].gold} == {0, 0}
    end

    test "every member gets at least 1 XP" do
      d =
        state()
        |> add([player(1, "a"), player(2, "b"), player(3, "c")])
        |> put_monster("a", monster(hp: 1, xp: 1, gold: 0))

      {:ok, d, _} = Engine.attack(d, 1)
      assert Enum.all?(Map.values(d.players), &(&1.xp == 1))
    end

    test "levelling up raises max HP and attack and heals fully" do
      d =
        state()
        |> add(player(1, "alice", hp: 3, xp: 15))
        |> put_monster("a", monster(hp: 1, xp: 5))

      {:ok, d, text} = Engine.attack(d, 1)
      assert %Player{level: 2, xp: 0, max_hp: 25, hp: 25, attack: 5} = d.players[1]
      assert text =~ "alice reaches level 2"
    end

    test "a big XP haul can level up several times" do
      d = state() |> add(player(1, "alice")) |> put_monster("a", monster(hp: 1, xp: 65))
      {:ok, d, text} = Engine.attack(d, 1)
      # 20 for level 2, 40 for level 3, 5 left over.
      assert %Player{level: 3, xp: 5, max_hp: 30, attack: 6} = d.players[1]
      assert text =~ "level 2"
      assert text =~ "level 3"
    end
  end

  describe "take/2" do
    test "picks up everything in the room" do
      d =
        state()
        |> add(player(1, "alice", inventory: ["potion"]))
        |> put_items("a", ["elixir", "whetstone"])

      assert {:ok, d, text} = Engine.take(d, 1)
      assert d.players[1].inventory == ["potion", "elixir", "whetstone"]
      assert d.rooms["a"].items == []
      assert text =~ "elixir, whetstone"
    end

    test "fails on an empty floor" do
      d = add(state(), player(1, "alice"))
      assert {:error, msg} = Engine.take(d, 1)
      assert msg =~ "nothing here to take"
    end

    test "monsters guard their loot" do
      d =
        state()
        |> add(player(1, "alice"))
        |> put_items("a", ["potion"])
        |> put_monster("a", monster())

      assert {:error, msg} = Engine.take(d, 1)
      assert msg =~ "won't let you near"
    end

    test "downed players can't loot" do
      d = state() |> add(player(1, "alice", hp: 0)) |> put_items("a", ["potion"])
      assert {:error, _} = Engine.take(d, 1)
    end
  end

  describe "use_item/3" do
    test "a potion heals up to 10 HP without exceeding max" do
      d = add(state(), player(1, "alice", hp: 5, inventory: ["potion", "potion"]))
      assert {:ok, d, text} = Engine.use_item(d, 1, "potion")
      assert d.players[1].hp == 15
      assert d.players[1].inventory == ["potion"]
      assert text =~ "recovers 10 HP"

      {:ok, d, text} = Engine.use_item(d, 1, "potion")
      assert d.players[1].hp == 20
      assert text =~ "recovers 5 HP"
    end

    test "an elixir raises max HP by 3 and heals fully" do
      d = add(state(), player(1, "alice", hp: 2, inventory: ["elixir"]))
      {:ok, d, _} = Engine.use_item(d, 1, "elixir")
      assert {d.players[1].hp, d.players[1].max_hp} == {23, 23}
    end

    test "a whetstone raises attack by 1" do
      d = add(state(), player(1, "alice", inventory: ["whetstone"]))
      {:ok, d, _} = Engine.use_item(d, 1, "whetstone")
      assert d.players[1].attack == 5
    end

    test "item names are trimmed and case-insensitive" do
      d = add(state(), player(1, "alice", hp: 1, inventory: ["potion"]))
      assert {:ok, _, _} = Engine.use_item(d, 1, "  PoTiOn ")
    end

    test "you can't use what you don't have" do
      d = add(state(), player(1, "alice"))
      assert {:error, "You don't have a potion."} = Engine.use_item(d, 1, "potion")
      assert {:error, "You don't have anything like that."} = Engine.use_item(d, 1, "")
    end

    test "unusable items stay in the pack" do
      d = add(state(), player(1, "alice", inventory: ["rock"]))
      assert {:error, msg} = Engine.use_item(d, 1, "rock")
      assert msg =~ "can't use the rock"
    end

    test "downed players can't drink potions" do
      d = add(state(), player(1, "alice", hp: 0, inventory: ["potion"]))
      assert {:error, msg} = Engine.use_item(d, 1, "potion")
      assert msg =~ "/revive"
    end
  end

  describe "revive/3" do
    setup do
      %{d: add(state(), [player(1, "alice"), player(2, "Bob", hp: 0, max_hp: 25)])}
    end

    test "restores a downed ally in the same room to half HP", %{d: d} do
      assert {:ok, d, text} = Engine.revive(d, 1, "Bob")
      assert d.players[2].hp == 12
      assert text =~ "alice revives Bob (12/25 HP)"
    end

    test "matches names case-insensitively with an optional @", %{d: d} do
      assert {:ok, _, _} = Engine.revive(d, 1, " @bob ")
    end

    test "fails for unknown names, standing allies, or other rooms", %{d: d} do
      assert {:error, _} = Engine.revive(d, 1, "zed")
      assert {:error, _} = Engine.revive(d, 1, "")

      standing = put_in(d.players[2].hp, 5)
      assert {:error, _} = Engine.revive(standing, 1, "bob")

      elsewhere = put_in(d.players[2].room_id, "b")
      assert {:error, _} = Engine.revive(elsewhere, 1, "bob")
    end

    test "the downed can't revive anyone", %{d: d} do
      d = add(d, player(3, "carol", hp: 0))
      assert {:error, msg} = Engine.revive(d, 3, "bob")
      assert msg =~ "carol, you are down"
    end

    test "you can't revive yourself", %{d: d} do
      assert {:error, _} = Engine.revive(d, 2, "bob")
    end
  end

  describe "rest/2" do
    test "heals fully at the entrance" do
      d = add(state(), player(1, "alice", hp: 3))
      assert {:ok, d, _} = Engine.rest(d, 1)
      assert d.players[1].hp == 20
    end

    test "is only allowed at the entrance" do
      d = add(state(), player(1, "alice", hp: 3, room_id: "b"))
      assert {:error, msg} = Engine.rest(d, 1)
      assert msg =~ "entrance"
    end
  end

  describe "descend/2" do
    setup do
      d =
        add(state(), [
          player(1, "alice", room_id: "c", hp: 4),
          player(2, "bob", room_id: "b", hp: 0),
          player(3, "carol", room_id: "d", hp: 18)
        ])

      %{d: d}
    end

    test "requires stairs", %{d: d} do
      assert {:error, msg} = Engine.descend(d, 3)
      assert msg =~ "no stairs"
    end

    test "requires the guardian to be dead", %{d: d} do
      d = put_monster(d, "c", monster(name: "Wraith"))
      assert {:error, msg} = Engine.descend(d, 1)
      assert msg =~ "Wraith blocks the stairs"
    end

    test "takes the whole party to a fresh floor", %{d: d} do
      assert {:ok, d2, text} = Engine.descend(d, 1)
      assert d2.depth == 2
      assert d2.seed == d.seed
      assert {d2.rooms, d2.start_room} == Dungeon.World.generate(d.seed, 2)
      assert Enum.all?(Map.values(d2.players), &(&1.room_id == d2.start_room))
      assert text =~ "alice leads the party down to depth 2"
    end

    test "patches everyone up to at least half HP, carrying the fallen", %{d: d} do
      {:ok, d2, _} = Engine.descend(d, 1)
      assert d2.players[1].hp == 10
      assert d2.players[2].hp == 10
      assert d2.players[3].hp == 18
    end
  end

  describe "status/2" do
    test "shows the character sheet" do
      d =
        add(
          state(),
          player(1, "alice", level: 2, xp: 7, gold: 3, inventory: ["potion", "elixir"])
        )

      {:ok, ^d, text} = Engine.status(d, 1)
      assert text =~ "alice — level 2 (7/40 XP)"
      assert text =~ "HP 20/20 · Attack 4 · Gold 3"
      assert text =~ "Pack: potion, elixir"
    end

    test "shows an empty pack and works while downed" do
      d = add(state(), player(1, "alice", hp: 0))
      {:ok, _, text} = Engine.status(d, 1)
      assert text =~ "Pack: empty"
    end
  end

  describe "party/1" do
    test "with nobody in the dungeon" do
      assert {:ok, _, text} = Engine.party(state())
      assert text =~ "Nobody is in the dungeon"
    end

    test "lists everyone by level, then name, with location and state" do
      d =
        add(state(), [
          player(1, "zed", level: 3, room_id: "c"),
          player(2, "bob", hp: 0),
          player(3, "amy", room_id: "b")
        ])

      {:ok, _, text} = Engine.party(d)

      assert String.split(text, "\n") == [
               "🏰 Depth 1 — party of 3",
               "• zed (lvl 3, 20/20 HP) in Stairwell",
               "• amy (lvl 1, 20/20 HP) in Hall",
               "• bob (lvl 1, 💀 down) in Entrance"
             ]
    end
  end

  test "unknown players get a hint to join for every action" do
    d = state()

    for result <- [
          Engine.look(d, 9),
          Engine.move(d, 9, "east"),
          Engine.attack(d, 9),
          Engine.take(d, 9),
          Engine.use_item(d, 9, "potion"),
          Engine.revive(d, 9, "x"),
          Engine.rest(d, 9),
          Engine.descend(d, 9),
          Engine.status(d, 9)
        ] do
      assert {:error, msg} = result
      assert msg =~ "/join"
    end
  end
end
