defmodule Dungeon.FakeTelegram do
  @moduledoc """
  A minimal HTTP/1.1 server standing in for api.telegram.org.

  Every request is forwarded to the owning test process as
  `{:telegram, method, decoded_body}`, and answered by `handler`, a function
  `(method, body) -> {status, map} | {:raw, status, binary}`.
  """

  @doc """
  Starts the server on a free local port. Returns `{pid, base_url}`; pass
  `base_url` as the client's `:api_base`.
  """
  def start(handler) do
    owner = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept(listen, owner, handler) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    {pid, "http://127.0.0.1:#{port}"}
  end

  # Serves one connection at a time, forever. Each response closes its
  # connection, so every request arrives on a fresh one.
  defp accept(listen, owner, handler) do
    {:ok, socket} = :gen_tcp.accept(listen)
    serve(socket, owner, handler)
    accept(listen, owner, handler)
  end

  defp serve(socket, owner, handler) do
    with {:ok, method, body} <- read_request(socket) do
      decoded = if body == "", do: nil, else: :json.decode(body)
      send(owner, {:telegram, method, decoded})

      {status, payload} =
        case handler.(method, decoded) do
          {:raw, status, raw} -> {status, raw}
          {status, map} -> {status, IO.iodata_to_binary(:json.encode(map))}
        end

      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\n",
        "content-length: #{byte_size(payload)}\r\nconnection: close\r\n\r\n",
        payload
      ])
    end

    :gen_tcp.close(socket)
  end

  # Reads one request using the VM's built-in HTTP parser (packet:
  # :http_bin), which yields the request line and then one header at a
  # time. The body is then read raw, using Content-Length. Returns
  # {:ok, method, body}, where the method is the last path segment, e.g.
  # "sendMessage" from "/bot<token>/sendMessage".
  defp read_request(socket) do
    :ok = :inet.setopts(socket, packet: :http_bin)

    with {:ok, {:http_request, _verb, {:abs_path, path}, _}} <- :gen_tcp.recv(socket, 0, 5_000),
         {:ok, length} <- read_headers(socket, 0) do
      :ok = :inet.setopts(socket, packet: :raw)
      {:ok, body} = if length > 0, do: :gen_tcp.recv(socket, length, 5_000), else: {:ok, ""}
      {:ok, Path.basename(path), body}
    end
  end

  defp read_headers(socket, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} ->
        {:ok, length}

      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        read_headers(socket, String.to_integer(value))

      {:ok, {:http_header, _, _, _, _}} ->
        read_headers(socket, length)

      other ->
        other
    end
  end
end
