defmodule SentientwaveAutomataWeb.Plugs.RequireServiceAuth do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  alias SentientwaveAutomata.RuntimeConfig

  def init(opts), do: opts

  def call(conn, _opts) do
    case configured_token() do
      "" ->
        if RuntimeConfig.production?() do
          unauthorized(conn)
        else
          conn
        end

      token ->
        if valid_token?(request_token(conn), token) do
          conn
        else
          unauthorized(conn)
        end
    end
  end

  defp configured_token do
    System.get_env("AUTOMATA_API_TOKEN", "")
    |> String.trim()
  end

  defp request_token(conn) do
    bearer_token(conn) ||
      header_token(conn, "x-automata-service-token") ||
      header_token(conn, "x-api-key") ||
      ""
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token -> String.trim(token)
      _ -> nil
    end
  end

  defp header_token(conn, header_name) do
    conn
    |> get_req_header(header_name)
    |> List.first()
    |> case do
      nil -> nil
      value -> String.trim(value)
    end
  end

  defp valid_token?(left, right)
       when byte_size(left) == byte_size(right) and byte_size(left) > 0 do
    Plug.Crypto.secure_compare(left, right)
  end

  defp valid_token?(_, _), do: false

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "service_auth_required"})
    |> halt()
  end
end
