defmodule Dungeon.Monster do
  @moduledoc false
  defstruct [:name, :hp, :max_hp, :attack, :xp, :gold]
end

defmodule Dungeon.Room do
  @moduledoc false
  # exits: direction ("north", ...) => room id
  defstruct [:id, :name, :description, exits: %{}, monster: nil, items: [], stairs?: false]
end

defmodule Dungeon.Player do
  @moduledoc false
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

  def down?(%__MODULE__{hp: hp}), do: hp <= 0
end

defmodule Dungeon.State do
  @moduledoc "One shared dungeon instance, bound to a single Telegram chat."
  defstruct [:chat_id, :seed, :start_room, depth: 1, rooms: %{}, players: %{}]
end
