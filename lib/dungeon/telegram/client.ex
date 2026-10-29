defmodule Dungeon.Telegram.Client do
  @moduledoc """
  Minimal Telegram Bot API client built on OTP's `:httpc` and `:json`,
  so the app has no third-party dependencies.
  """

  @doc """
  Routes requests through `HTTPS_PROXY` when set (`:httpc` ignores the
  environment on its own).
  """
  def configure_proxy do
    case System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") do
      empty when empty in [nil, ""] ->
        :ok

      url ->
        %URI{host: host, port: port} = URI.parse(url)
        :httpc.set_options(https_proxy: {{String.to_charlist(host), port}, []})
    end
  end

  def get_updates(token, offset, timeout) do
    call(
      token,
      "getUpdates",
      %{offset: offset, timeout: timeout, allowed_updates: ["message"]},
      :timer.seconds(timeout + 10)
    )
  end

  def send_message(token, chat_id, text) do
    call(token, "sendMessage", %{chat_id: chat_id, text: text})
  end

  def set_my_commands(token, commands) do
    call(token, "setMyCommands", %{commands: commands})
  end

  defp call(token, method, body, timeout \\ :timer.seconds(15)) do
    url = ~c"https://api.telegram.org/bot#{token}/#{method}"
    request = {url, [], ~c"application/json", IO.iodata_to_binary(:json.encode(body))}
    http_opts = [timeout: timeout, connect_timeout: :timer.seconds(10), ssl: ssl_opts()]

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, resp}} ->
        case decode(resp) do
          %{"ok" => true, "result" => result} -> {:ok, result}
          decoded -> {:error, {status, decoded}}
        end

      # Never include the URL in errors: it contains the bot token.
      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # Network/TLS problems must never crash the poller; it retries instead.
    e -> {:error, Exception.message(e)}
  end

  defp decode(body) do
    :json.decode(body)
  rescue
    _ -> body
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
