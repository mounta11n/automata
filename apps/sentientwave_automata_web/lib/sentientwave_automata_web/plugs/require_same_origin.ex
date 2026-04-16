defmodule SentientwaveAutomataWeb.Plugs.RequireSameOrigin do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  @safe_methods ~w(GET HEAD OPTIONS)

  def init(opts), do: opts

  def call(%Plug.Conn{method: method} = conn, _opts) when method in @safe_methods, do: conn

  def call(conn, _opts) do
    if same_origin?(conn) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "same_origin_required"})
      |> halt()
    end
  end

  defp same_origin?(conn) do
    conn
    |> request_origin()
    |> case do
      nil -> false
      origin -> compare_origin(origin, conn)
    end
  end

  defp request_origin(conn) do
    header_value(conn, "origin") || header_value(conn, "referer")
  end

  defp compare_origin(value, conn) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) ->
        host == conn.host and normalized_port(scheme, port) == conn.port

      _ ->
        false
    end
  end

  defp normalized_port("http", nil), do: 80
  defp normalized_port("https", nil), do: 443
  defp normalized_port(_scheme, nil), do: nil
  defp normalized_port(_scheme, port), do: port

  defp header_value(conn, name) do
    conn
    |> get_req_header(name)
    |> List.first()
    |> case do
      nil -> nil
      value -> String.trim(value)
    end
  end
end
