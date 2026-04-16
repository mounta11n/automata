defmodule SentientwaveAutomata.Agents.Embedding.OpenAI do
  @moduledoc """
  OpenAI embeddings provider for production-grade memory ingestion and retrieval.
  """

  @behaviour SentientwaveAutomata.Agents.EmbeddingProvider

  @default_model "text-embedding-3-small"
  @default_base_url "https://api.openai.com/v1"

  @impl true
  def embed(text, opts \\ []) when is_binary(text) do
    api_key =
      Keyword.get(
        opts,
        :api_key,
        System.get_env(
          "AUTOMATA_EMBEDDING_API_KEY",
          System.get_env("AUTOMATA_LLM_API_KEY", System.get_env("OPENAI_API_KEY", ""))
        )
      )
      |> to_string()
      |> String.trim()

    if api_key == "" do
      {:error, :missing_api_key}
    else
      model =
        Keyword.get(opts, :model, System.get_env("AUTOMATA_EMBEDDING_MODEL", @default_model))
        |> to_string()
        |> String.trim()

      base_url =
        Keyword.get(
          opts,
          :base_url,
          System.get_env("AUTOMATA_EMBEDDING_API_BASE", @default_base_url)
        )
        |> to_string()
        |> String.trim()

      payload =
        %{
          "input" => text,
          "model" => if(model == "", do: @default_model, else: model)
        }
        |> maybe_put_dimensions(Keyword.get(opts, :dim))

      case Req.post(
             url: String.trim_trailing(base_url, "/") <> "/embeddings",
             headers: [
               {"content-type", "application/json"},
               {"authorization", "Bearer " <> api_key}
             ],
             json: payload,
             receive_timeout: timeout_ms(),
             connect_options: [timeout: connect_timeout_ms()],
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          extract_embedding(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp extract_embedding(%{"data" => [%{"embedding" => embedding} | _]})
       when is_list(embedding) do
    {:ok, Enum.map(embedding, &normalize_number/1)}
  end

  defp extract_embedding(body), do: {:error, {:invalid_response, body}}

  defp maybe_put_dimensions(payload, dim) when is_integer(dim) and dim > 0 do
    Map.put(payload, "dimensions", dim)
  end

  defp maybe_put_dimensions(payload, _dim), do: payload

  defp normalize_number(value) when is_float(value), do: value
  defp normalize_number(value) when is_integer(value), do: value / 1
  defp normalize_number(value), do: value

  defp timeout_ms do
    System.get_env("AUTOMATA_EMBEDDING_TIMEOUT_MS", "30000")
    |> String.to_integer()
  rescue
    _ -> 30_000
  end

  defp connect_timeout_ms do
    System.get_env("AUTOMATA_EMBEDDING_CONNECT_TIMEOUT_MS", "3000")
    |> String.to_integer()
  rescue
    _ -> 3_000
  end
end
