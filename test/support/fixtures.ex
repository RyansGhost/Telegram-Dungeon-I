defmodule Dungeon.Fixtures do
  @moduledoc """
  A tiny hand-built dungeon, so engine tests don't depend on generation:

                 d (Closet)
                 |
      a (Entrance) — b (Hall) — c (Stairwell)
  """

  alias Dungeon.{Monster, Player, Room, State}

  def state do
    rooms = %{
      "a" => %Room{id: "a", name: "Entrance", description: "Safe.", exits: %{"east" => "b"}},
      "b" => %Room{
        id: "b",
        name: "Hall",
        description: "Dusty.",
        exits: %{"west" => "a", "east" => "c", "north" => "d"}
      },
      "c" => %Room{
        id: "c",
        name: "Stairwell",
        description: "Down.",
        exits: %{"west" => "b"},
        stairs?: true
      },
      "d" => %Room{id: "d", name: "Closet", description: "Cramped.", exits: %{"south" => "b"}}
    }

    %State{chat_id: -1, seed: 42, depth: 1, start_room: "a", rooms: rooms}
  end

  def player(id, name, attrs \\ []) do
    struct!(%Player{user_id: id, name: name, room_id: "a"}, attrs)
  end

  def monster(attrs \\ []) do
    struct!(%Monster{name: "Rat", hp: 5, max_hp: 5, attack: 1, xp: 10, gold: 4}, attrs)
  end

  def add(%State{} = state, players) when is_list(players),
    do: Enum.reduce(players, state, &add(&2, &1))

  def add(%State{} = state, %Player{} = p), do: put_in(state.players[p.user_id], p)

  def put_monster(state, room_id, monster), do: put_in(state.rooms[room_id].monster, monster)
  def put_items(state, room_id, items), do: put_in(state.rooms[room_id].items, items)
end
