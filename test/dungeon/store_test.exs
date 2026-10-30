# Saving and loading dungeons in PostgreSQL, through the application's real
# Repo (the test database configured in config.exs). Each test uses its own
# chat id, so tests don't see each other's data and can run concurrently.
defmodule Dungeon.StoreTest do
  use ExUnit.Case, async: true

  import Dungeon.Fixtures, only: [monster: 1]
  import Ecto.Query

  alias Dungeon.{Engine, Repo, Store}
  alias Dungeon.Store.{PlayerRow, RoomRow}

  defp chat_id, do: System.unique_integer()

  defp count(schema, chat_id),
    do: Repo.aggregate(from(r in schema, where: r.chat_id == ^chat_id), :count)

  # A dungeon with something in every column: players with progress and
  # inventories, a wounded monster, loot, and the stairwell.
  defp busy_dungeon(id) do
    {:ok, d, _} = Engine.join(Engine.new(id, 5), 1, "alice")
    {:ok, d, _} = Engine.join(d, 2, "bob")
    d = put_in(d.players[1], %{d.players[1] | hp: 7, level: 3, xp: 12, gold: 40})
    d = put_in(d.players[2].inventory, ["potion", "potion", "whetstone"])
    d = put_in(d.rooms[d.start_room].items, ["elixir"])
    put_in(d.rooms[d.start_room].monster, monster(name: "Ogre", hp: 3, max_hp: 9))
  end

  test "returns nil for an unknown chat" do
    assert Store.load(chat_id()) == nil
  end

  test "round-trips a dungeon exactly" do
    id = chat_id()
    d = busy_dungeon(id)
    Store.save(d)
    assert Store.load(id) == d
  end

  test "stores one row per player and per room" do
    id = chat_id()
    d = busy_dungeon(id)
    Store.save(d)
    assert count(PlayerRow, id) == 2
    assert count(RoomRow, id) == map_size(d.rooms)
  end

  test "handles Telegram's large supergroup ids" do
    id = -1_001_234_567_890 - System.unique_integer([:positive])
    {:ok, d, _} = Engine.join(Engine.new(id, 1), 9_876_543_210, "carol")
    Store.save(d)
    assert Store.load(id) == d
  end

  test "incremental saves stay exact through a whole game" do
    # Play a scripted game, saving each step against the previous state the
    # way GameServer does, and check the database matches after every step.
    id = chat_id()
    :rand.seed(:exsss, {4, 5, 6})
    d0 = Engine.new(id, 77)
    {stairs_id, _} = Enum.find(d0.rooms, fn {_, r} -> r.stairs? end)
    [{dir, _} | _] = Map.to_list(d0.rooms[d0.start_room].exits)

    steps = [
      &Engine.join(&1, 1, "alice"),
      &Engine.join(&1, 2, "bob"),
      &Engine.move(&1, 1, dir),
      # Put alice on the stairs with the guardian nearly dead, then fight.
      fn d ->
        d = put_in(d.players[1].room_id, stairs_id)
        {:ok, put_in(d.rooms[stairs_id].monster.hp, 1), ""}
      end,
      &Engine.attack(&1, 1),
      fn d -> {:ok, put_in(d.rooms[stairs_id].items, ["potion"]), ""} end,
      &Engine.take(&1, 1),
      &Engine.use_item(&1, 1, "potion"),
      &Engine.descend(&1, 1),
      &Engine.leave(&1, 2)
    ]

    Enum.reduce(steps, {d0, nil}, fn step, {d, saved} ->
      {:ok, d, _} = step.(d)
      Store.save(d, saved)
      assert Store.load(id) == d
      {d, d}
    end)

    # After descending, only the new floor's rooms remain, and bob is gone.
    final = Store.load(id)
    assert final.depth == 2
    assert count(RoomRow, id) == map_size(final.rooms)
    assert count(PlayerRow, id) == 1
  end

  test "a reset replaces everything" do
    id = chat_id()
    d = busy_dungeon(id)
    Store.save(d)

    fresh = Engine.new(id, 6)
    Store.save(fresh, d)
    assert Store.load(id) == fresh
    assert count(PlayerRow, id) == 0
  end

  test "updates keep the original inserted_at" do
    id = chat_id()
    d = busy_dungeon(id)
    Store.save(d)
    inserted = Repo.get_by!(PlayerRow, chat_id: id, user_id: 1)

    Store.save(put_in(d.players[1].gold, 99), d)
    updated = Repo.get_by!(PlayerRow, chat_id: id, user_id: 1)

    assert updated.gold == 99
    assert updated.inserted_at == inserted.inserted_at
    assert DateTime.compare(updated.updated_at, inserted.updated_at) == :gt
  end

  test "chats are stored independently" do
    [a, b] = [chat_id(), chat_id()]
    Store.save(Engine.new(a, 1))
    Store.save(Engine.new(b, 2))
    assert Store.load(a).seed == 1
    assert Store.load(b).seed == 2
  end

  test "a failed save writes nothing" do
    id = chat_id()
    {:ok, d, _} = Engine.join(Engine.new(id, 3), 1, "alice")
    Store.save(d)

    # Change alice's gold, and give a room a NULL name, which the schema
    # rejects. Players are written before rooms, so the gold change succeeds
    # first and must then be rolled back with the rest of the transaction.
    broken = put_in(d.players[1].gold, 50)
    broken = put_in(broken.rooms[d.start_room].name, nil)

    assert_raise Postgrex.Error, fn -> Store.save(broken, d) end
    assert Store.load(id) == d
  end
end
