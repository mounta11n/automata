defmodule SentientwaveAutomata.Agents.Tools.HTTP do
  @moduledoc false

  @spec get_json(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, integer(), map()} | {:error, term()}
  def get_json(url, headers, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())
    connect_timeout = Keyword.get(opts, :connect_timeout, default_connect_timeout())

    case Req.get(url,
           headers: headers,
           receive_timeout: timeout,
           connect_options: [timeout: connect_timeout]
         ) do
      {:ok, %Req.Response{status: status, body: body}} ->
        decode_json(status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json(status, body) when is_map(body), do: {:ok, status, body}

  defp decode_json(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, status, json}
      {:error, reason} -> {:error, {:invalid_json_response, reason, body}}
    end
  end

  defp decode_json(_status, body), do: {:error, {:invalid_json_response, :unexpected_body, body}}

  defp default_timeout do
    System.get_env("AUTOMATA_TOOL_HTTP_TIMEOUT_MS", "12000")
    |> String.to_integer()
  rescue
    _ -> 12_000
  end

  defp default_connect_timeout do
    System.get_env("AUTOMATA_TOOL_HTTP_CONNECT_TIMEOUT_MS", "3000")
    |> String.to_integer()
  rescue
    _ -> 3_000
  end
end
