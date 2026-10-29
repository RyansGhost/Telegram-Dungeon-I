defmodule Dungeon.Telegram.Client do
  @moduledoc """
  Minimal Telegram Bot API client built on OTP's `:httpc` and `:json`,
  so the app has no third-party dependencies.

  Every Bot API method is an HTTPS POST to
  `https://api.telegram.org/bot<token>/<method>` with a JSON body. Telegram
  answers `{"ok": true, "result": ...}` on success, or `{"ok": false,
  "description": ...}` on failure.

  Each function returns `{:ok, result}` or `{:error, reason}`; it never
  raises, so network trouble can't crash the caller. The API base URL can be
  overridden with the `:api_base` application setting, which the tests use
  to point the client at a local fake server.
  """

  @doc """
  Routes requests through `HTTPS_PROXY` when set (`:httpc` ignores the
  environment on its own). Called once, when the poller starts.
  """
  def configure_proxy do
    case System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") do
      empty when empty in [nil, ""] ->
        :ok

      url ->
        %URI{host: host, port: port} = URI.parse(url)
        # The empty list is :httpc's "no proxy" exception list.
        :httpc.set_options(https_proxy: {{String.to_charlist(host), port}, []})
    end
  end

  @doc """
  Long-polls for new messages (`getUpdates`): Telegram holds the request open
  for up to `timeout` seconds until something arrives.

  `offset` is one more than the last update id already handled; passing it
  tells Telegram those updates are done and won't be sent again.
  """
  def get_updates(token, offset, timeout) do
    call(
      token,
      "getUpdates",
      %{offset: offset, timeout: timeout, allowed_updates: ["message"]},
      # Allow the HTTP request a little longer than Telegram may hold it.
      :timer.seconds(timeout + 10)
    )
  end

  @doc "Posts a plain-text message to a chat (`sendMessage`)."
  def send_message(token, chat_id, text) do
    call(token, "sendMessage", %{chat_id: chat_id, text: text})
  end

  @doc """
  Sets the command menu Telegram shows when users type `/`
  (`setMyCommands`). `commands` is a list of `%{command:, description:}`.
  """
  def set_my_commands(token, commands) do
    call(token, "setMyCommands", %{commands: commands})
  end

  # Makes one Bot API call: POSTs `body` as JSON, then unwraps Telegram's
  # {"ok": ..., "result": ...} envelope.
  defp call(token, method, body, timeout \\ :timer.seconds(15)) do
    base = Application.get_env(:dungeon, :api_base, "https://api.telegram.org")
    # :httpc wants charlists (~c"...") rather than strings for the URL and
    # content type.
    url = ~c"#{base}/bot#{token}/#{method}"
    request = {url, [], ~c"application/json", IO.iodata_to_binary(:json.encode(body))}
    # Explicit even for plain HTTP: :httpc otherwise loads the OS CA store
    # for every request, which raises on systems without one.
    ssl = if String.starts_with?(base, "https:"), do: ssl_opts(), else: []
    http_opts = [timeout: timeout, connect_timeout: :timer.seconds(10), ssl: ssl]

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, resp}} ->
        case decode(resp) do
          %{"ok" => true, "result" => result} -> {:ok, result}
          # Telegram's error JSON, or the raw body if it wasn't JSON (e.g. a
          # proxy's HTML error page).
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

  # Parses a JSON body, returning it unchanged if it isn't valid JSON.
  defp decode(body) do
    :json.decode(body)
  rescue
    _ -> body
  end

  # Verified TLS: check the server's certificate against the operating
  # system's trusted CAs, and check that it was issued for the hostname we
  # connected to. (Hence the Docker image installs ca-certificates.)
  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
