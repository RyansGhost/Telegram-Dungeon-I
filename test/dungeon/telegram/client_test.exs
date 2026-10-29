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
