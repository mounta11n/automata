defmodule SentientwaveAutomata.Agents.LawCompliance do
  @moduledoc """
  Certifies agent decisions against the currently bound constitution snapshot.
  """

  alias SentientwaveAutomata.Agents.LLM.Client
  alias SentientwaveAutomata.Agents.Run
  alias SentientwaveAutomata.Agents.Runtime

  @default_block_message "I can't complete that request because I couldn't certify the chosen response against the current company constitution. Please revise the request or update the governing laws."
  @context_excerpt_chars 2_000

  @spec certify_response(Run.t(), map(), map(), String.t()) :: {:ok, map()}
  def certify_response(%Run{} = run, attrs, context, response) when is_binary(response) do
    snapshot = resolve_snapshot(run)
    decision_payload = response_decision_payload(attrs, context, response)

    if certification_ready?(snapshot) do
      case Client.certify_decision(
             agent_id: run.agent_id,
             room_id: fetch_value(attrs, "room_id", ""),
             trace_context: certification_trace_context(run, attrs, snapshot),
             constitution_snapshot: snapshot,
             decision_type: "response",
             decision_payload: decision_payload
           ) do
        {:ok, certification} ->
          {:ok, enforce_block_message(certification)}

        {:error, reason} ->
          {:ok, blocked_certification(snapshot, certification_failure_summary(reason))}
      end
    else
      {:ok, blocked_certification(snapshot, "No published constitution snapshot is available.")}
    end
  end

  @spec certified?(map()) :: boolean()
  def certified?(certification) when is_map(certification) do
    Map.get(certification, "certified") == true and
      Map.get(certification, "enforcement") != "blocked"
  end

  def certified?(_certification), do: false

  @spec blocked_response(map()) :: String.t()
  def blocked_response(certification) when is_map(certification) do
    certification
    |> Map.get("block_message", @default_block_message)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @default_block_message
      message -> message
    end
  end

  def blocked_response(_certification), do: @default_block_message

  defp response_decision_payload(attrs, context, response) do
    input = fetch_map(attrs, "input")
    context_text = Map.get(context, :context_text) || Map.get(context, "context_text") || ""

    %{
      "decision_type" => "response",
      "user_input" => fetch_value(input, "body", "") |> normalize_text(),
      "proposed_response" => response |> to_string() |> String.trim(),
      "context_excerpt" =>
        context_text |> to_string() |> String.trim() |> truncate(@context_excerpt_chars),
      "room_id" => fetch_value(attrs, "room_id", ""),
      "conversation_scope" =>
        fetch_value(attrs, "conversation_scope") || fetch_value(input, "conversation_scope") ||
          "unknown"
    }
  end

  defp certification_trace_context(%Run{} = run, attrs, snapshot) do
    input = fetch_map(attrs, "input")

    %{
      "run_id" => run.id,
      "room_id" => fetch_value(attrs, "room_id", ""),
      "requested_by" => fetch_value(attrs, "requested_by"),
      "sender_mxid" => fetch_value(input, "sender_mxid") || fetch_value(attrs, "requested_by"),
      "conversation_scope" =>
        fetch_value(attrs, "conversation_scope") || fetch_value(input, "conversation_scope") ||
          "unknown",
      "constitution_snapshot_id" => Map.get(snapshot, "id"),
      "constitution_version" => Map.get(snapshot, "version"),
      "law_guard_decision_type" => "response",
      "law_guard_enabled" => true
    }
  end

  defp resolve_snapshot(%Run{} = run) do
    reference =
      Map.get(run, :metadata, %{})
      |> Runtime.constitution_snapshot_reference()

    current_snapshot = reference || Runtime.current_constitution_snapshot()
    snapshot_reference = Runtime.constitution_snapshot_reference(current_snapshot)

    %{
      "id" => snapshot_reference && Map.get(snapshot_reference, :id),
      "version" => snapshot_reference && Map.get(snapshot_reference, :version),
      "prompt_text" => Runtime.constitution_prompt_text(current_snapshot),
      "laws" => Runtime.constitution_laws(current_snapshot)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp certification_ready?(snapshot) when is_map(snapshot) do
    has_text?(Map.get(snapshot, "prompt_text")) or Map.get(snapshot, "laws", []) != []
  end

  defp certification_ready?(_snapshot), do: false

  defp blocked_certification(snapshot, summary) do
    evaluated_laws = normalize_evaluated_laws(Map.get(snapshot, "laws", []))

    violation =
      %{
        "law_name" => "Current Constitution",
        "reason" => summary
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      "decision_type" => "response",
      "certified" => false,
      "enforcement" => "blocked",
      "summary" => summary,
      "violations" => [violation],
      "constitution_snapshot_id" => Map.get(snapshot, "id"),
      "constitution_version" => Map.get(snapshot, "version"),
      "law_count" => length(evaluated_laws),
      "evaluated_laws" => evaluated_laws,
      "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "block_message" => @default_block_message
    }
  end

  defp enforce_block_message(certification) when is_map(certification) do
    case Map.get(certification, "certified") do
      true ->
        certification

      _ ->
        Map.put_new(certification, "block_message", @default_block_message)
    end
  end

  defp certification_failure_summary(reason) do
    "Law certification failed: #{inspect(reason)}"
  end

  defp normalize_evaluated_laws(laws) when is_list(laws) do
    Enum.map(laws, fn law ->
      %{
        "id" => Map.get(law, "id"),
        "slug" => Map.get(law, "slug"),
        "name" => Map.get(law, "name"),
        "law_kind" => Map.get(law, "law_kind"),
        "markdown_body" => Map.get(law, "markdown_body"),
        "prompt_text" => Map.get(law, "prompt_text"),
        "version" => Map.get(law, "version"),
        "position" => Map.get(law, "position")
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp normalize_evaluated_laws(_laws), do: []

  defp fetch_map(map, key) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp fetch_value(map, key, default \\ nil) when is_map(map) do
    atom_key =
      case key do
        "input" -> :input
        "body" -> :body
        "room_id" -> :room_id
        "requested_by" -> :requested_by
        "sender_mxid" -> :sender_mxid
        "conversation_scope" -> :conversation_scope
        _ -> nil
      end

    Map.get(map, key, atom_key && Map.get(map, atom_key, default)) || default
  end

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp truncate(text, limit) do
    if String.length(text) > limit do
      String.slice(text, 0, limit)
    else
      text
    end
  end

  defp has_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp has_text?(_value), do: false
end
