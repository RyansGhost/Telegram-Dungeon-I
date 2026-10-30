# Ecto schemas mapping the database tables (see priv/repo/migrations).
# These are storage rows only: the game works with the structs in
# structs.ex, and Dungeon.Store converts between the two.

defmodule Dungeon.Store.DungeonRow do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:chat_id, :integer, autogenerate: false}
  schema "dungeons" do
    field(:seed, :integer)
    field(:depth, :integer)
    field(:start_room, :string)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Dungeon.Store.PlayerRow do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "players" do
    field(:chat_id, :integer, primary_key: true)
    field(:user_id, :integer, primary_key: true)
    field(:name, :string)
    field(:room_id, :string)
    field(:hp, :integer)
    field(:max_hp, :integer)
    field(:attack, :integer)
    field(:level, :integer)
    field(:xp, :integer)
    field(:gold, :integer)
    field(:inventory, {:array, :string})
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Dungeon.Store.RoomRow do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "rooms" do
    field(:chat_id, :integer, primary_key: true)
    field(:room_id, :string, primary_key: true)
    field(:name, :string)
    field(:description, :string)
    field(:exits, :map)
    field(:monster, :map)
    field(:items, {:array, :string})
    field(:stairs, :boolean)
    timestamps(type: :utc_datetime_usec)
  end
end
