# The game's data model. These are plain structs with no behaviour beyond a
# helper or two: all rules live in Dungeon.Engine, and generation in
# Dungeon.World. Dungeon.Store maps them to PostgreSQL tables (State to
# `dungeons`, Player to `players`, Room to `rooms`, Monster to a JSONB column).

defmodule Dungeon.Monster do
  @moduledoc """
  A monster occupying a room.

    * `:hp` / `:max_hp` - current and starting health; it dies at 0 or below
    * `:attack` - upper bound of the damage it deals per hit (1..attack)
    * `:xp`, `:gold` - rewards, split among the party that kills it
  """
  defstruct [:name, :hp, :max_hp, :attack, :xp, :gold]
end

defmodule Dungeon.Room do
  @moduledoc """
  One room on a dungeon floor.

    * `:id` - the room's grid coordinates as a string, e.g. `"0,0"` or `"-1,2"`
    * `:exits` - map of direction (`"north"`, `"south"`, `"east"`, `"west"`)
      to the id of the neighbouring room
    * `:monster` - a `Dungeon.Monster`, or `nil` when the room is clear
    * `:items` - loot on the floor (item names such as `"potion"`)
    * `:stairs?` - true for the single stairwell leading to the next floor
  """
  defstruct [:id, :name, :description, exits: %{}, monster: nil, items: [], stairs?: false]
end

defmodule Dungeon.Player do
  @moduledoc """
  An adventurer: one Telegram user in one chat's dungeon.

    * `:user_id` - the Telegram user id (the key in `Dungeon.State.players`)
    * `:name` - display name shown in messages, and used by `/revive <name>`
    * `:room_id` - id of the room the player is standing in
    * `:attack` - upper bound of the player's base damage (1..attack, plus level)
    * `:xp` - progress towards the next level; resets on levelling up
    * `:inventory` - item names, duplicates allowed (two potions = two entries)

  A player at 0 HP is "down": they can't act until someone revives them.
  """
  defstruct [
    :user_id,
    :name,
    :room_id,
    hp: 20,
    max_hp: 20,
    attack: 4,
    level: 1,
    xp: 0,
    gold: 0,
    inventory: []
  ]

  @doc "True when the player has been knocked out (0 HP) and needs reviving."
  def down?(%__MODULE__{hp: hp}), do: hp <= 0
end

defmodule Dungeon.State do
  @moduledoc """
  One shared dungeon instance, bound to a single Telegram chat.

    * `:chat_id` - the Telegram chat this dungeon belongs to
    * `:seed` - fixed for the dungeon's lifetime; together with `:depth` it
      determines the current floor's layout (see `Dungeon.World.generate/3`)
    * `:depth` - current floor number, starting at 1
    * `:start_room` - id of the floor's entrance (where players arrive)
    * `:rooms` - map of room id to `Dungeon.Room` for the current floor
    * `:players` - map of Telegram user id to `Dungeon.Player`

  Only the current floor is kept: descending replaces `:rooms` entirely.
  """
  defstruct [:chat_id, :seed, :start_room, depth: 1, rooms: %{}, players: %{}]
end
