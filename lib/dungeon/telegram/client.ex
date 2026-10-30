defmodule Dungeon.Telegram.Client do
  @moduledoc """
  Minimal Telegram Bot API client built on OTP's built-in `:httpc` and
  `:json`, so talking to Telegram needs no extra libraries.

  Every Bot API method is an HTTPS POST to
  `https://api.telegram.org/bot<token>/<method>` with a JSON body. Telegram
  answers `{"ok": true, "result": ...}` on success, or `{"ok": false,
  "description": ...}` on failure.

  Each function returns `{:ok, result}` or `{:error, reason}`; it never
  raises, so network trouble can't crash the caller. When Telegram says a
  request was rate limited (429), it is retried once after the wait Telegram
  asks for, if that's 30 seconds or less. The API base URL can be
  overridden with the `:api_base` application setting, which the tests use
  to point the client at a local fake server.
  """

  @doc """
  Routes requests through `HTTPS_PROXY` when set (`:httpc` ignores the
  environment on its own). Called once, when the poller starts.
  """
  # Telegram's limit on one message, in UTF-16 code units (see utf16_length/1).
  @max_message_length 4096
  # The longest rate-limit wait that is worth sitting out before retrying.
  @max_retry_after 30

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

  @doc "Returns the bot's own user record (`getMe`), including its `username`."
  def get_me(token), do: call(token, "getMe", %{})

  @doc """
  Posts a plain-text message to a chat (`sendMessage`). Text longer than
  Telegram allows is sent as several messages, split at line breaks (see
  split_message/2). Stops at the first part that fails.
  """
  def send_message(token, chat_id, text) do
    text
    |> split_message()
    |> Enum.reduce_while({:ok, nil}, fn part, _ ->
      case call(token, "sendMessage", %{chat_id: chat_id, text: part}) do
        {:ok, _} = ok -> {:cont, ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Splits `text` into parts no longer than `limit`, packing whole lines into
  each part. Breaks fall between lines, which the split drops (joining the
  parts with newlines gives back the text), except that a single line
  longer than `limit` is itself cut between characters.
  """
  def split_message(text, limit \\ @max_message_length) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if utf16_length(line) <= limit, do: [line], else: pack(String.graphemes(line), "", limit)
    end)
    |> pack("\n", limit)
  end

  # Greedily joins `pieces` with `separator` into as few strings as possible,
  # each no longer than `limit`. Each piece must already fit on its own.
  defp pack(pieces, separator, limit) do
    Enum.chunk_while(
      pieces,
      nil,
      fn
        piece, nil ->
          {:cont, piece}

        piece, acc ->
          joined = acc <> separator <> piece
          if utf16_length(joined) <= limit, do: {:cont, joined}, else: {:cont, acc, piece}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
  end

  # Length as Telegram counts it: in UTF-16 code units, where most emoji
  # count as 2.
  defp utf16_length(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, :utf16)), 2)

  @doc """
  Sets the command menu Telegram shows when users type `/`
  (`setMyCommands`). `commands` is a list of `%{command:, description:}`.
  """
  def set_my_commands(token, commands) do
    call(token, "setMyCommands", %{commands: commands})
  end

  # Makes one Bot API call, retrying once if it was rate limited.
  defp call(token, method, body, timeout \\ :timer.seconds(15)) do
    case request(token, method, body, timeout) do
      {:error, {429, %{"parameters" => %{"retry_after" => wait}}}}
      when is_integer(wait) and wait <= @max_retry_after ->
        Process.sleep(:timer.seconds(wait))
        request(token, method, body, timeout)

      result ->
        result
    end
  end

  # Makes one HTTP request: POSTs `body` as JSON, then unwraps Telegram's
  # {"ok": ..., "result": ...} envelope.
  defp request(token, method, body, timeout) do
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
