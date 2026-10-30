defmodule Dungeon.Repo.Migrations.CreateGameTables do
  @moduledoc """
  The initial schema: one row per chat's dungeon, plus its players and the
  rooms of its current floor. Players and rooms belong to a dungeon, and are
  deleted with it.
  """
  use Ecto.Migration

  def change do
    create table(:dungeons, primary_key: false) do
      # Telegram chat ids exceed 32 bits (supergroups look like -100...).
      add :chat_id, :bigint, primary_key: true
      add :seed, :bigint, null: false
      add :depth, :integer, null: false
      add :start_room, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:players, primary_key: false) do
      add :chat_id,
          references(:dungeons, column: :chat_id, type: :bigint, on_delete: :delete_all),
          primary_key: true

      add :user_id, :bigint, primary_key: true
      add :name, :text, null: false
      add :room_id, :text, null: false
      add :hp, :integer, null: false
      add :max_hp, :integer, null: false
      add :attack, :integer, null: false
      add :level, :integer, null: false
      add :xp, :integer, null: false
      add :gold, :integer, null: false
      add :inventory, {:array, :text}, null: false, default: []
      timestamps(type: :utc_datetime_usec)
    end

    # For finding one person's characters across all chats.
    create index(:players, [:user_id])

    create table(:rooms, primary_key: false) do
      add :chat_id,
          references(:dungeons, column: :chat_id, type: :bigint, on_delete: :delete_all),
          primary_key: true

      add :room_id, :text, primary_key: true
      add :name, :text, null: false
      add :description, :text, null: false
      # Direction => neighbouring room id, e.g. {"north": "0,1"}.
      add :exits, :map, null: false
      # The monster's stats as an object, or NULL when the room is clear.
      add :monster, :map
      add :items, {:array, :text}, null: false, default: []
      add :stairs, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
