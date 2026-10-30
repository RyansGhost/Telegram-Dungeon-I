defmodule Dungeon.Repo do
  @moduledoc """
  The connection pool to PostgreSQL. All database access goes through it;
  see `Dungeon.Store`. Connection settings come from config/runtime.exs
  (`DATABASE_URL`).
  """
  use Ecto.Repo, otp_app: :dungeon, adapter: Ecto.Adapters.Postgres
end
