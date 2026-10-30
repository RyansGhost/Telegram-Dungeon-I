# The Bot API client, tested against Dungeon.FakeTelegram (a local HTTP
# server) by pointing the :api_base setting at it. The fake reports each
# request it receives to the test as a message, which assert_receive checks.
defmodule Dungeon.Telegram.ClientTest do
  # Not async: these tests change the global API base and :httpc options.
  use ExUnit.Case

  @moduletag :capture_log

  alias Dungeon.FakeTelegram
  alias Dungeon.Telegram.Client

  setup do
    on_exit(fn -> Application.delete_env(:dungeon, :api_base) end)
  end

  defp fake(handler) do
    {_pid, base} = FakeTelegram.start(handler)
    Application.put_env(:dungeon, :api_base, base)
  end

  test "sendMessage posts JSON and returns the result" do
    fake(fn "sendMessage", _ -> {200, %{ok: true, result: %{message_id: 7}}} end)

    assert {:ok, %{"message_id" => 7}} = Client.send_message("tok", 42, "hi ⚔️")
    assert_receive {:telegram, "sendMessage", %{"chat_id" => 42, "text" => "hi ⚔️"}}
  end

  test "getUpdates sends offset, timeout and allowed updates" do
    fake(fn "getUpdates", _ -> {200, %{ok: true, result: [%{update_id: 1}]}} end)

    assert {:ok, [%{"update_id" => 1}]} = Client.get_updates("tok", 5, 0)

    assert_receive {:telegram, "getUpdates",
                    %{"offset" => 5, "timeout" => 0, "allowed_updates" => ["message"]}}
  end

  test "setMyCommands sends the command list" do
    fake(fn "setMyCommands", _ -> {200, %{ok: true, result: true}} end)

    assert {:ok, true} = Client.set_my_commands("tok", [%{command: "join", description: "Join"}])

    assert_receive {:telegram, "setMyCommands",
                    %{"commands" => [%{"command" => "join", "description" => "Join"}]}}
  end

  test "getMe returns the bot's user record" do
    fake(fn "getMe", _ -> {200, %{ok: true, result: %{id: 1, username: "DungeonBot"}}} end)
    assert {:ok, %{"username" => "DungeonBot"}} = Client.get_me("tok")
  end

  describe "rate limiting" do
    # Answers 429 ("retry after `wait` seconds") the first time, then OK.
    defp rate_limited_once(wait) do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fake(fn _, _ ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {429, %{ok: false, error_code: 429, parameters: %{retry_after: wait}}}
          _ -> {200, %{ok: true, result: %{message_id: 1}}}
        end
      end)
    end

    test "a 429 is retried once after the requested wait" do
      rate_limited_once(0)
      assert {:ok, %{"message_id" => 1}} = Client.send_message("tok", 1, "x")
      assert_receive {:telegram, "sendMessage", _}
      assert_receive {:telegram, "sendMessage", _}
    end

    test "a long wait isn't sat out" do
      rate_limited_once(300)
      assert {:error, {429, _}} = Client.send_message("tok", 1, "x")
      assert_receive {:telegram, "sendMessage", _}
      refute_receive {:telegram, "sendMessage", _}, 100
    end
  end

  describe "long messages" do
    test "are sent in parts that each fit Telegram's limit" do
      fake(fn _, _ -> {200, %{ok: true, result: %{message_id: 1}}} end)
      lines = for i <- 1..300, do: "🏰 line #{i} of a very long party list"
      text = Enum.join(lines, "\n")

      assert {:ok, _} = Client.send_message("tok", 1, text)

      parts = collect_sent([])
      assert length(parts) > 1
      assert Enum.join(parts, "\n") == text
    end

    test "stop at the first part that fails" do
      fake(fn _, _ -> {400, %{ok: false, description: "Bad Request"}} end)
      text = String.duplicate("x\n", 3000)
      assert {:error, {400, _}} = Client.send_message("tok", 1, text)
      assert_receive {:telegram, "sendMessage", _}
      refute_receive {:telegram, "sendMessage", _}, 100
    end

    # Every text the fake server received, in order.
    defp collect_sent(acc) do
      receive do
        {:telegram, "sendMessage", %{"text" => t}} -> collect_sent([t | acc])
      after
        200 -> Enum.reverse(acc)
      end
    end
  end

  describe "split_message/2" do
    test "leaves short text alone" do
      assert Client.split_message("hello\nworld") == ["hello\nworld"]
      assert Client.split_message("") == [""]
    end

    test "packs whole lines into each part" do
      assert Client.split_message("aa\nbb\ncc\ndd", 5) == ["aa\nbb", "cc\ndd"]
    end

    test "cuts a single over-long line between characters" do
      assert Client.split_message("abcdefg", 3) == ["abc", "def", "g"]
    end

    test "counts length the way Telegram does, with emoji as 2" do
      # ⚔ is 1 UTF-16 unit (it's in the Basic Multilingual Plane); 💀 is
      # outside it, so it takes 2. "⚔⚔\n💀💀" is 2 + 1 + 4 = 7 units.
      assert Client.split_message("⚔⚔\n💀💀", 4) == ["⚔⚔", "💀💀"]
      assert Client.split_message("💀💀💀", 4) == ["💀💀", "💀"]
    end

    test "never produces a part over Telegram's 4096 limit" do
      text = Enum.map_join(1..2_000, "\n", &"☠️ #{&1}")
      parts = Client.split_message(text)

      assert Enum.all?(
               parts,
               &(div(byte_size(:unicode.characters_to_binary(&1, :utf8, :utf16)), 2) <= 4096)
             )

      assert Enum.join(parts, "\n") == text
    end
  end

  test "API errors come back as {:error, {status, body}}" do
    fake(fn _, _ -> {409, %{ok: false, error_code: 409, description: "Conflict"}} end)
    assert {:error, {409, %{"description" => "Conflict"}}} = Client.send_message("tok", 1, "x")
  end

  test "non-JSON responses are returned raw" do
    fake(fn _, _ -> {:raw, 502, "Bad Gateway"} end)
    assert {:error, {502, "Bad Gateway"}} = Client.send_message("tok", 1, "x")
  end

  test "connection failures are errors, not crashes" do
    # Grab a free port and close it again, so nothing is listening there.
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    Application.put_env(:dungeon, :api_base, "http://127.0.0.1:#{port}")

    assert {:error, reason} = Client.send_message("secret-token", 1, "x")
    refute inspect(reason) =~ "secret-token"
  end

  test "HTTPS failures are errors too" do
    # Exercises the TLS settings used for the real API. Nothing listens on
    # the port, so the connection fails (or, on a system without a CA store,
    # loading the certificates does); either way it must be an error.
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    Application.put_env(:dungeon, :api_base, "https://127.0.0.1:#{port}")

    assert {:error, _} = Client.send_message("tok", 1, "x")
  end

  describe "configure_proxy/0" do
    # Proxy settings are global to :httpc, so restore them afterwards.
    setup do
      {:ok, [https_proxy: original]} = :httpc.get_options([:https_proxy])

      on_exit(fn ->
        System.delete_env("HTTPS_PROXY")
        System.delete_env("https_proxy")
        :httpc.set_options(https_proxy: original)
      end)
    end

    test "uses HTTPS_PROXY when set" do
      System.put_env("HTTPS_PROXY", "http://proxy.lan:3128")
      Client.configure_proxy()

      assert {:ok, [https_proxy: {{~c"proxy.lan", 3128}, []}]} =
               :httpc.get_options([:https_proxy])
    end

    test "falls back to lowercase https_proxy" do
      System.delete_env("HTTPS_PROXY")
      System.put_env("https_proxy", "http://10.0.0.2:8080")
      Client.configure_proxy()
      assert {:ok, [https_proxy: {{~c"10.0.0.2", 8080}, []}]} = :httpc.get_options([:https_proxy])
    end

    test "does nothing when unset or empty" do
      {:ok, before} = :httpc.get_options([:https_proxy])
      System.put_env("HTTPS_PROXY", "")
      assert Client.configure_proxy() == :ok
      assert :httpc.get_options([:https_proxy]) == {:ok, before}
    end
  end
end
