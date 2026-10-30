defmodule Dungeon.Store do
  @moduledoc """
  Persists each chat's `Dungeon.State` in PostgreSQL.

  A dungeon is stored across three tables (see priv/repo/migrations):

    * `dungeons` - one row per chat: seed, depth and entrance
    * `players` - one row per player in that chat: all character progress
    * `rooms` - one row per room on the chat's current floor, including any
      monster's remaining HP and loot still on the floor

  The game itself never touches the database: `Dungeon.GameServer` loads a
  chat's state when it starts, and calls save/2 after each change. save/2
  compares the new state with the last one saved and writes only the rows
  that differ, all in one transaction, so a save is all-or-nothing.
  """

  import Ecto.Query

  alias Dungeon.{Monster, Player, Repo, Room, State}
  alias Dungeon.Store.{DungeonRow, PlayerRow, RoomRow}

  # Player fields stored as columns of the same name.
  @player_fields [
    :user_id,
    :name,
    :room_id,
    :hp,
    :max_hp,
    :attack,
    :level,
    :xp,
    :gold,
    :inventory
  ]

  @doc "Returns the saved dungeon for `chat_id`, or `nil` if there isn't one."
  def load(chat_id) do
    case Repo.get(DungeonRow, chat_id) do
      nil ->
        nil

      row ->
        players = Repo.all(from(p in PlayerRow, where: p.chat_id == ^chat_id))
        rooms = Repo.all(from(r in RoomRow, where: r.chat_id == ^chat_id))

        %State{
          chat_id: chat_id,
          seed: row.seed,
          depth: row.depth,
          start_room: row.start_room,
          players: Map.new(players, &{&1.user_id, to_player(&1)}),
          rooms: Map.new(rooms, &{&1.room_id, to_room(&1)})
        }
    end
  end

  @doc """
  Saves a chat's dungeon.

  `previous` is the state as last saved (or loaded), or `nil` if this chat
  has never been saved. Only differences from it are written: changed or new
  players and rooms are upserted, and ones that no longer exist (a player who
  left, the rooms of a floor the party descended from) are deleted.

  Raises if the database rejects the write, in which case nothing is saved.
  """
  def save(%State{chat_id: chat_id} = state, previous \\ nil) do
    now = DateTime.utc_now()

    {:ok, :ok} =
      Repo.transaction(fn ->
        # The dungeon row goes first: players and rooms reference it.
        if previous == nil or dungeon_fields(previous) != dungeon_fields(state) do
          upsert(DungeonRow, [Map.put(dungeon_fields(state), :chat_id, chat_id)], [:chat_id], now)
        end

        sync(
          PlayerRow,
          :user_id,
          chat_id,
          players_of(previous),
          state.players,
          &player_row/1,
          now
        )

        sync(RoomRow, :room_id, chat_id, rooms_of(previous), state.rooms, &room_row/1, now)
        :ok
      end)

    :ok
  end

  # Brings one table in line with a map of entities (players or rooms, keyed
  # by `key`): deletes rows whose key is gone, upserts entities that are new
  # or differ from the previous state.
  defp sync(schema, key, chat_id, old, new, to_row, now) do
    case Map.keys(old) -- Map.keys(new) do
      [] ->
        :ok

      removed ->
        Repo.delete_all(
          from(r in schema, where: r.chat_id == ^chat_id and field(r, ^key) in ^removed)
        )
    end

    case for({k, v} <- new, Map.get(old, k) != v, do: Map.put(to_row.(v), :chat_id, chat_id)) do
      [] -> :ok
      rows -> upsert(schema, rows, [:chat_id, key], now)
    end
  end

  # Inserts rows, or updates them where the primary key already exists.
  # `inserted_at` is kept from the original insert; `updated_at` is refreshed.
  defp upsert(schema, rows, conflict_target, now) do
    rows = Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

    Repo.insert_all(schema, rows,
      on_conflict: {:replace_all_except, conflict_target ++ [:inserted_at]},
      conflict_target: conflict_target
    )
  end

  defp players_of(nil), do: %{}
  defp players_of(state), do: state.players

  defp rooms_of(nil), do: %{}
  defp rooms_of(state), do: state.rooms

  ## Conversions between game structs and database rows

  defp dungeon_fields(state), do: Map.take(state, [:seed, :depth, :start_room])

  defp player_row(%Player{} = p), do: Map.take(p, @player_fields)
  defp to_player(%PlayerRow{} = row), do: struct!(Player, Map.take(row, @player_fields))

  defp room_row(%Room{} = r) do
    %{
      room_id: r.id,
      name: r.name,
      description: r.description,
      exits: r.exits,
      monster: r.monster && Map.from_struct(r.monster),
      items: r.items,
      stairs: r.stairs?
    }
  end

  defp to_room(%RoomRow{} = row) do
    %Room{
      id: row.room_id,
      name: row.name,
      description: row.description,
      exits: row.exits,
      monster: row.monster && to_monster(row.monster),
      items: row.items,
      stairs?: row.stairs
    }
  end

  # JSONB comes back with string keys: {"hp": 5} -> %Monster{hp: 5}.
  # to_existing_atom only accepts names that are already Monster fields.
  defp to_monster(map) do
    struct!(Monster, for({k, v} <- map, do: {String.to_existing_atom(k), v}))
  end
end
