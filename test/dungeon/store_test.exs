# Saving and loading dungeons. These use the application's real Store (on
# the test database configured in config.exs), with a unique chat id per
# test so they don't see each other's data.
defmodule Dungeon.StoreTest do
  # Not async: one test restarts the store, which every other test relies on.
  use ExUnit.Case

  alias Dungeon.{Engine, Store}

  defp chat_id, do: System.unique_integer()

  test "returns nil for an unknown chat" do
    assert Store.load(chat_id()) == nil
  end

  test "round-trips a dungeon" do
    id = chat_id()
    {:ok, d, _} = Engine.join(Engine.new(id, 5), 1, "alice")
    Store.save(d)
    assert Store.load(id) == d
  end

  test "saving again overwrites" do
    id = chat_id()
    d = Engine.new(id, 5)
    Store.save(d)
    Store.save(%{d | depth: 4})
    assert Store.load(id).depth == 4
  end

  test "chats are stored independently" do
    [a, b] = [chat_id(), chat_id()]
    Store.save(Engine.new(a, 1))
    Store.save(Engine.new(b, 2))
    assert Store.load(a).seed == 1
    assert Store.load(b).seed == 2
  end

  test "state survives the store restarting" do
    id = chat_id()
    Store.save(Engine.new(id, 77))

    # Kill the store outright (no clean shutdown) and wait for the
    # supervisor to start a replacement.
    pid = Process.whereis(Store)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}

    wait_for(fn -> Process.whereis(Store) not in [nil, pid] end)
    # The name is registered before init/1 reopens the file; wait for init.
    :sys.get_state(Store)
    assert Store.load(id).seed == 77
  end

  # Polls `fun` every 20 ms, for up to a second, until it returns true.
  defp wait_for(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end
end
