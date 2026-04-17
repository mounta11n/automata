defmodule SentientwaveAutomata.Agents.LLM.Client do
  @moduledoc """
  Abstracted LLM inference client with provider selection via runtime config/env.
  """

  require Logger
  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.DeepResearch
  alias SentientwaveAutomata.Agents.LLM.TraceRecorder
  alias SentientwaveAutomata.Agents.Runtime
  alias SentientwaveAutomata.Agents.Tools.Executor
  alias SentientwaveAutomata.Settings

  @max_reply_chars 4_000

  @spec generate_response(keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_response(opts) do
    with {:ok, plan} <- plan_tool_calls(opts) do
      case Map.get(plan, :tool_calls, []) do
        [] ->
          generate_response_without_tools(opts)

        tool_calls ->
          case execute_tool_calls(Keyword.get(opts, :agent_id), tool_calls) do
            {:ok, tool_context} when tool_context != [] ->
              synthesize_tool_response(opts, tool_context)

            _ ->
              generate_response_without_tools(opts)
          end
      end
    else
      {:error, reason} ->
        Logger.warning("llm_provider_error reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec generate_response_without_tools(keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_response_without_tools(opts) do
    %{messages: messages, provider_opts: provider_opts, provider: provider} = response_state(opts)

    with {:ok, module} <- provider_module(provider),
         {:ok, text} <- traced_complete(module, messages, provider_opts, "response", 0),
         text when is_binary(text) and text != "" <- sanitize_text(text) do
      {:ok, text}
    else
      {:error, reason} ->
        Logger.warning("llm_provider_error provider=#{provider} reason=#{inspect(reason)}")
        {:error, reason}

      _ ->
        {:error, :empty_llm_response}
    end
  end

  @spec plan_tool_calls(keyword()) ::
          {:ok, %{tool_calls: [map()], available_tools: [map()]}} | {:error, term()}
  def plan_tool_calls(opts) do
    %{
      messages: base_messages,
      provider_opts: provider_opts,
      provider: provider,
      user_input: user_input,
      agent_id: agent_id
    } = state = response_state(opts)

    available_tools = Executor.available_tools(agent_id)

    cond do
      available_tools == [] ->
        {:ok, %{tool_calls: [], available_tools: []}}

      true ->
        with {:ok, module} <- provider_module(provider),
             {:ok, tool_calls} <-
               plan_with_heuristics_or_model(
                 module,
                 base_messages,
                 user_input,
                 available_tools,
                 provider_opts
               ) do
          {:ok, %{tool_calls: tool_calls, available_tools: available_tools, state: state}}
        end
    end
  end

  @spec execute_tool_calls(binary() | nil, [map()]) :: {:ok, [map()]} | {:error, term()}
  def execute_tool_calls(agent_id, tool_calls) when is_list(tool_calls) do
    available_tools = Executor.available_tools(agent_id)
    execute_tool_plan(tool_calls, available_tools)
  end

  @spec synthesize_tool_response(keyword(), [map()]) :: {:ok, String.t()} | {:error, term()}
  def synthesize_tool_response(opts, tool_context) when is_list(tool_context) do
    if tool_context == [] do
      generate_response_without_tools(opts)
    else
      %{
        messages: base_messages,
        provider_opts: provider_opts,
        provider: provider
      } = response_state(opts)

      tool_result_messages = [
        %{
          "role" => "system",
          "content" =>
            "Tool execution results are available for your reasoning. " <>
              "Do not mention internal tool names, JSON payloads, IDs, or workflow internals in the user-facing response. " <>
              "Summarize the outcome in plain language.\n\n#{Jason.encode!(%{"tool_results" => tool_context})}"
        }
      ]

      with {:ok, module} <- provider_module(provider),
           {:ok, text} <-
             traced_complete(
               module,
               base_messages ++ tool_result_messages,
               provider_opts,
               "tool_response",
               1
             ),
           text when is_binary(text) and text != "" <- sanitize_text(text) do
        {:ok, text}
      else
        _ -> generate_response_without_tools(opts)
      end
    end
  end

  @spec deep_research_decision(keyword()) :: map()
  def deep_research_decision(opts) when is_list(opts) do
    user_input =
      Keyword.get(opts, :user_input, "")
      |> to_string()
      |> String.trim()

    available_tools =
      Keyword.get(opts, :available_tools) ||
        Executor.available_tools(Keyword.get(opts, :agent_id))

    explicit? = explicit_deep_research?(opts)
    fallback = DeepResearch.fallback_decision(user_input, available_tools)

    cond do
      not DeepResearch.should_consider?(user_input, available_tools) and not explicit? ->
        fallback

      true ->
        %{
          messages: base_messages,
          provider_opts: provider_opts,
          provider: provider
        } = response_state(opts)

        with {:ok, module} <- provider_module(provider),
             {:ok, response} <-
               traced_complete(
                 module,
                 base_messages ++
                   [deep_research_decision_message(available_tools, explicit?)],
                 provider_opts,
                 "deep_research_decision",
                 0
               ),
             {:ok, payload} <- extract_json_object(response) do
          DeepResearch.normalize_decision(payload, user_input, available_tools)
        else
          _ -> fallback
        end
    end
  end

  @spec review_deep_research_round(keyword(), map()) :: {:ok, map()} | {:error, term()}
  def review_deep_research_round(opts, round_payload)
      when is_list(opts) and is_map(round_payload) do
    %{
      messages: base_messages,
      provider_opts: provider_opts,
      provider: provider
    } = response_state(opts)

    evidence = Map.get(round_payload, "evidence", [])
    round_index = normalize_round_index(Map.get(round_payload, "round_index"))
    max_rounds = normalize_max_rounds(Map.get(round_payload, "max_rounds"))
    prior_summary = Map.get(round_payload, "prior_summary", "")

    fallback =
      DeepResearch.normalize_round_review(%{}, evidence, round_index, max_rounds)

    with {:ok, module} <- provider_module(provider),
         {:ok, response} <-
           traced_complete(
             module,
             base_messages ++
               [
                 deep_research_review_message(
                   evidence,
                   prior_summary,
                   round_index,
                   max_rounds
                 )
               ],
             provider_opts,
             "deep_research_review",
             round_index
           ),
         {:ok, payload} <- extract_json_object(response) do
      {:ok, DeepResearch.normalize_round_review(payload, evidence, round_index, max_rounds)}
    else
      _ -> {:ok, fallback}
    end
  end

  @spec synthesize_deep_research_response(keyword(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def synthesize_deep_research_response(opts, research_payload)
      when is_list(opts) and is_map(research_payload) do
    %{
      messages: base_messages,
      provider_opts: provider_opts,
      provider: provider
    } = response_state(opts)

    with {:ok, module} <- provider_module(provider),
         {:ok, text} <-
           traced_complete(
             module,
             base_messages ++ [deep_research_result_message(research_payload)],
             provider_opts,
             "deep_research_response",
             0
           ),
         text when is_binary(text) and text != "" <- sanitize_text(text) do
      {:ok, text}
    else
      {:error, reason} ->
        Logger.warning(
          "deep_research_response_failed provider=#{provider} reason=#{inspect(reason)}"
        )

        {:error, reason}

      _ ->
        {:error, :empty_llm_response}
    end
  end

  @spec certify_decision(keyword()) :: {:ok, map()} | {:error, term()}
  def certify_decision(opts) when is_list(opts) do
    effective = Settings.llm_provider_effective()
    provider = Keyword.get(opts, :provider, effective.provider)
    model = Keyword.get(opts, :model, effective.model)
    timeout_seconds = Keyword.get(opts, :timeout_seconds, effective.timeout_seconds || 600)
    agent_id = Keyword.get(opts, :agent_id)
    trace_context = Keyword.get(opts, :trace_context, %{})
    decision_type = normalize_decision_type(Keyword.get(opts, :decision_type, "decision"))
    decision_payload = normalize_decision_payload(Keyword.get(opts, :decision_payload, %{}))
    constitution_snapshot = Keyword.get(opts, :constitution_snapshot)
    constitution_prompt_text = Runtime.constitution_prompt_text(constitution_snapshot)
    evaluated_laws = Runtime.constitution_laws(constitution_snapshot)

    provider_opts =
      [
        model: model,
        timeout_seconds: timeout_seconds,
        agent_id: agent_id,
        room_id: Keyword.get(opts, :room_id),
        trace_context: trace_context,
        provider: provider,
        provider_config_id: effective.id
      ]
      |> maybe_put_provider_opt(:base_url, effective.base_url)
      |> maybe_put_provider_opt(:api_key, effective.api_token)

    with {:ok, module} <- provider_module(provider),
         {:ok, response} <-
           traced_complete(
             module,
             certification_messages(
               decision_type,
               decision_payload,
               constitution_prompt_text,
               evaluated_laws
             ),
             provider_opts,
             "law_certification",
             0
           ),
         {:ok, payload} <- extract_json_object(response) do
      {:ok,
       normalize_law_certification(
         payload,
         decision_type,
         constitution_snapshot,
         evaluated_laws
       )}
    else
      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_law_certification_response}
    end
  end

  defp provider_module("openai"), do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.OpenAI}

  defp provider_module("openrouter"),
    do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.OpenRouter}

  defp provider_module("anthropic"),
    do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Anthropic}

  defp provider_module("gemini"),
    do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Gemini}

  defp provider_module("cerebras"),
    do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Cerebras}

  defp provider_module("lm-studio"), do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.LMStudio}
  defp provider_module("ollama"), do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Ollama}
  defp provider_module("local"), do: {:ok, SentientwaveAutomata.Agents.LLM.Providers.Local}
  defp provider_module(other), do: {:error, {:unsupported_llm_provider, other}}

  defp sanitize_text(text) do
    text
    |> String.trim()
    |> String.slice(0, @max_reply_chars)
  end

  defp constitution_messages(prompt_text) when is_binary(prompt_text) do
    trimmed = String.trim(prompt_text)

    if trimmed == "" do
      []
    else
      [
        %{
          "role" => "system",
          "content" =>
            "Company constitution and governance laws.\n\n" <>
              "These rules are binding for all reasoning, planning, and tool use.\n\n" <>
              trimmed
        }
      ]
    end
  end

  defp constitution_messages(_), do: []

  defp plan_with_heuristics_or_model(module, base_messages, user_input, available_tools, opts) do
    with {:ok, plan} <- heuristic_tool_plan(user_input, available_tools, opts),
         true <- plan != [] do
      {:ok, plan}
    else
      false ->
        run_model_tool_planner(module, base_messages, user_input, available_tools, opts)

      {:error, _reason} ->
        run_model_tool_planner(module, base_messages, user_input, available_tools, opts)
    end
  end

  defp run_model_tool_planner(module, base_messages, user_input, available_tools, opts) do
    with {:ok, tool_plan_text} <-
           traced_complete(
             module,
             base_messages ++ [tool_planner_message(available_tools)],
             opts,
             "tool_planner",
             0
           ),
         {:ok, plan} <-
           parse_or_infer_tool_plan(tool_plan_text, user_input, available_tools, opts) do
      {:ok, plan}
    else
      _ -> {:ok, []}
    end
  end

  defp response_state(opts) do
    effective = Settings.llm_provider_effective()
    agent_slug = Keyword.get(opts, :agent_slug, "automata")
    user_input = Keyword.get(opts, :user_input, "") |> to_string() |> String.trim()
    provider = Keyword.get(opts, :provider, effective.provider)
    model = Keyword.get(opts, :model, effective.model)
    timeout_seconds = Keyword.get(opts, :timeout_seconds, effective.timeout_seconds || 600)
    agent_id = Keyword.get(opts, :agent_id)
    context_text = Keyword.get(opts, :context_text, "") |> to_string() |> String.trim()
    trace_context = Keyword.get(opts, :trace_context, %{})
    constitution_snapshot = Keyword.get(opts, :constitution_snapshot)

    constitution_prompt_text =
      Keyword.get(opts, :constitution_prompt_text) ||
        Runtime.constitution_prompt_text(constitution_snapshot)

    provider_opts =
      [
        model: model,
        timeout_seconds: timeout_seconds,
        agent_id: agent_id,
        user_input: user_input,
        room_id: Keyword.get(opts, :room_id)
      ]
      |> maybe_put_provider_opt(:base_url, effective.base_url)
      |> maybe_put_provider_opt(:api_key, effective.api_token)
      |> Keyword.put(:trace_context, trace_context)
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:provider_config_id, effective.id)

    messages =
      [
        %{
          "role" => "system",
          "content" => system_prompt(agent_slug)
        }
      ] ++
        constitution_messages(constitution_prompt_text) ++
        skill_messages(agent_id) ++
        context_messages(context_text) ++
        [%{"role" => "user", "content" => user_prompt(user_input)}]

    %{
      provider: provider,
      provider_opts: provider_opts,
      messages: messages,
      user_input: user_input,
      agent_id: agent_id
    }
  end

  defp traced_complete(module, messages, opts, call_kind, sequence_index) do
    call_meta = %{
      agent_id: Keyword.get(opts, :agent_id),
      provider: Keyword.get(opts, :provider),
      provider_config_id: Keyword.get(opts, :provider_config_id),
      model: Keyword.get(opts, :model),
      base_url: Keyword.get(opts, :base_url),
      timeout_seconds: Keyword.get(opts, :timeout_seconds),
      trace_context: Keyword.get(opts, :trace_context, %{}),
      messages: messages,
      call_kind: call_kind,
      sequence_index: sequence_index
    }

    TraceRecorder.record_completion(call_meta, fn ->
      module.complete(
        messages,
        Keyword.drop(opts, [:trace_context, :provider, :provider_config_id])
      )
    end)
  end

  defp maybe_put_provider_opt(opts, _key, value) when value in [nil, ""], do: opts

  defp maybe_put_provider_opt(opts, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> opts
      trimmed -> Keyword.put(opts, key, trimmed)
    end
  end

  defp maybe_put_provider_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp tool_planner_message(available_tools) do
    %{
      "role" => "system",
      "content" =>
        "Tool calling is available. " <>
          "If a tool is needed, respond ONLY as JSON with shape " <>
          "{\"tool_calls\":[{\"name\":\"tool_name\",\"arguments\":{}}]}. " <>
          "If no tools are needed, respond ONLY with {\"tool_calls\":[]}. " <>
          "Available tools: #{inspect(tool_specs(available_tools))}"
    }
  end

  defp deep_research_decision_message(available_tools, explicit?) do
    limits = DeepResearch.config()
    tool_names = Enum.map(available_tools, &(Map.get(&1, :name) || Map.get(&1, "name")))

    %{
      "role" => "system",
      "content" =>
        "Decide whether this request requires deep research. " <>
          "Deep research is appropriate when the user explicitly asks for it or when the task needs fresh external evidence, comparison, investigation, or multi-step synthesis. " <>
          "Return ONLY JSON with keys enabled, reason, max_rounds, queries, and focus_areas. " <>
          "Set max_rounds between 1 and #{limits["max_rounds"]}. " <>
          "Keep queries to #{limits["max_queries_per_round"]} or fewer short web-search queries. " <>
          "Available tools: #{inspect(tool_names)}. " <>
          if(explicit?,
            do: "The user explicitly requested deeper research. Bias toward enabled=true.",
            else: ""
          )
    }
  end

  defp deep_research_review_message(evidence, prior_summary, round_index, max_rounds) do
    evidence_text = DeepResearch.render_evidence_for_prompt(evidence)
    limits = DeepResearch.config()

    %{
      "role" => "system",
      "content" =>
        "Review the current deep research evidence and decide whether more research is needed. " <>
          "Return ONLY JSON with keys round_summary, key_findings, continue_research, follow_up_queries, and top_sources. " <>
          "Keep follow_up_queries to #{limits["max_queries_per_round"]} or fewer. " <>
          "Only continue when the evidence is still incomplete and the next round will materially improve the answer. " <>
          "This is round #{round_index} of #{max_rounds}.\n\n" <>
          "Prior summary:\n#{blank_if_empty(prior_summary)}\n\n" <>
          "Current evidence:\n#{blank_if_empty(evidence_text)}"
    }
  end

  defp deep_research_result_message(research_payload) do
    %{
      "role" => "system",
      "content" =>
        "Deep research findings are available for your final answer. " <>
          "Write a plain-text response for the user. Do not use markdown bullets, JSON, or internal workflow language. " <>
          "Use the gathered evidence, mention uncertainty when sources disagree, and prefer concise paragraphs.\n\n" <>
          Jason.encode!(%{"deep_research" => research_payload})
    }
  end

  defp certification_messages(decision_type, decision_payload, constitution_prompt_text, laws) do
    [
      %{
        "role" => "system",
        "content" =>
          "You are the Automata governance law compliance certifier. " <>
            "Evaluate whether the proposed agent decision satisfies the current constitution. " <>
            "Return ONLY JSON with keys certified, summary, violations, and optional block_message. " <>
            "Each violation must be an object with law_slug, law_name, and reason. " <>
            "Set certified=false if the decision violates any law or you cannot certify it."
      }
    ] ++
      constitution_messages(constitution_prompt_text) ++
      [
        %{
          "role" => "user",
          "content" =>
            Jason.encode!(%{
              "decision_type" => decision_type,
              "decision" => decision_payload,
              "laws" => normalize_evaluated_laws(laws)
            })
        }
      ]
  end

  defp tool_specs(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    end)
  end

  defp parse_or_infer_tool_plan(text, user_input, available_tools, opts) do
    case parse_tool_plan(text) do
      {:ok, calls} ->
        {:ok, calls}

      _ ->
        heuristic_tool_plan(user_input, available_tools, opts)
    end
  end

  defp parse_tool_plan(text) when is_binary(text) do
    trimmed = String.trim(text)

    candidate =
      case Jason.decode(trimmed) do
        {:ok, payload} ->
          {:ok, payload}

        _ ->
          extract_json_object(trimmed)
      end

    with {:ok, payload} <- candidate,
         calls when is_list(calls) <- Map.get(payload, "tool_calls", []) do
      {:ok, calls}
    else
      _ -> {:error, :invalid_tool_plan}
    end
  end

  defp execute_tool_plan(tool_calls, available_tools) do
    tool_calls
    |> Enum.take(2)
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, acc} ->
      tool_name = call |> Map.get("name", "") |> to_string()
      args = Map.get(call, "arguments", %{})

      case Executor.execute(tool_name, args, available_tools) do
        {:ok, result} ->
          {:cont, {:ok, [%{"name" => tool_name, "result" => result} | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp heuristic_tool_plan(user_input, available_tools, opts) do
    _ = {user_input, available_tools, opts}
    {:ok, []}
  end

  defp extract_json_object(text) do
    case Regex.run(~r/\{[\s\S]*\}/u, text) do
      [json] -> Jason.decode(json)
      _ -> {:error, :no_json_object}
    end
  end

  defp normalize_law_certification(payload, decision_type, constitution_snapshot, laws)
       when is_map(payload) do
    snapshot_reference = Runtime.constitution_snapshot_reference(constitution_snapshot) || %{}
    evaluated_laws = normalize_evaluated_laws(laws)
    violations = normalize_certification_violations(Map.get(payload, "violations"))

    certified =
      truthy?(Map.get(payload, "certified")) and violations == []

    summary =
      payload
      |> Map.get("summary")
      |> normalize_certification_text()
      |> case do
        "" when certified ->
          "The proposed #{decision_type} satisfies the current constitution."

        "" ->
          "The proposed #{decision_type} could not be certified against the current constitution."

        value ->
          value
      end

    %{
      "decision_type" => decision_type,
      "certified" => certified,
      "enforcement" => if(certified, do: "allowed", else: "blocked"),
      "summary" => summary,
      "violations" => violations,
      "constitution_snapshot_id" => snapshot_reference[:id],
      "constitution_version" => snapshot_reference[:version],
      "law_count" => length(evaluated_laws),
      "evaluated_laws" => evaluated_laws,
      "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> maybe_put_certification_block_message(payload, certified)
  end

  defp normalize_law_certification(_payload, decision_type, constitution_snapshot, laws) do
    normalize_law_certification(%{}, decision_type, constitution_snapshot, laws)
  end

  defp maybe_put_certification_block_message(certification, _payload, true), do: certification

  defp maybe_put_certification_block_message(certification, payload, false) do
    block_message =
      payload
      |> Map.get("block_message", "")
      |> normalize_certification_text()

    if block_message == "" do
      certification
    else
      Map.put(certification, "block_message", block_message)
    end
  end

  defp normalize_certification_violations(violations) when is_list(violations) do
    violations
    |> Enum.map(fn
      %{} = violation ->
        %{
          "law_slug" => violation |> Map.get("law_slug", Map.get(violation, :law_slug)),
          "law_name" => violation |> Map.get("law_name", Map.get(violation, :law_name)),
          "reason" => violation |> Map.get("reason", Map.get(violation, :reason))
        }
        |> Enum.map(fn {key, value} -> {key, normalize_certification_text(value)} end)
        |> Enum.reject(fn {_key, value} -> value == "" end)
        |> Map.new()

      _ ->
        %{}
    end)
    |> Enum.reject(&(&1 == %{}))
  end

  defp normalize_certification_violations(_violations), do: []

  defp normalize_evaluated_laws(laws) when is_list(laws) do
    Enum.map(laws, fn law ->
      %{
        "id" => Map.get(law, "id"),
        "slug" => law |> Map.get("slug", Map.get(law, :slug)),
        "name" => law |> Map.get("name", Map.get(law, :name)),
        "law_kind" => law |> Map.get("law_kind", Map.get(law, :law_kind)),
        "markdown_body" => law |> Map.get("markdown_body", Map.get(law, :markdown_body)),
        "prompt_text" => law |> Map.get("prompt_text", Map.get(law, :prompt_text)),
        "version" => law |> Map.get("version", Map.get(law, :version)),
        "position" => law |> Map.get("position", Map.get(law, :position))
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  defp normalize_evaluated_laws(_laws), do: []

  defp normalize_decision_type(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "decision"
      normalized -> normalized
    end
  end

  defp normalize_decision_payload(%{} = payload) do
    payload
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_decision_value(value)} end)
    |> Map.new()
  end

  defp normalize_decision_payload(payload) do
    %{"value" => normalize_decision_value(payload)}
  end

  defp normalize_decision_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_decision_value(value) when is_boolean(value), do: value
  defp normalize_decision_value(value) when is_integer(value), do: value
  defp normalize_decision_value(value) when is_float(value), do: value
  defp normalize_decision_value(nil), do: nil
  defp normalize_decision_value(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_decision_value(value) when is_list(value) do
    Enum.map(value, &normalize_decision_value/1)
  end

  defp normalize_decision_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, entry} -> {to_string(key), normalize_decision_value(entry)} end)
    |> Map.new()
  end

  defp normalize_decision_value(value), do: inspect(value)

  defp normalize_certification_text(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp truthy?(value), do: value in [true, "true", "TRUE", "1", 1]

  defp explicit_deep_research?(opts) do
    Keyword.get(opts, :deep_research) in [true, "true", "1"] or
      Keyword.get(opts, :research_mode) in [:deep, "deep", "deep_research"]
  end

  defp normalize_round_index(value) when is_integer(value) and value > 0, do: value

  defp normalize_round_index(value) do
    case Integer.parse(to_string(value || "")) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_max_rounds(value) when is_integer(value) and value > 0, do: value

  defp normalize_max_rounds(value) do
    limit = DeepResearch.config()["max_rounds"]

    case Integer.parse(to_string(value || "")) do
      {parsed, _} when parsed > 0 -> min(parsed, limit)
      _ -> limit
    end
  end

  defp blank_if_empty(value) do
    case value |> to_string() |> String.trim() do
      "" -> "No prior summary."
      trimmed -> trimmed
    end
  end

  defp skill_messages(nil), do: []

  defp skill_messages(agent_id) when is_binary(agent_id) do
    case Agents.list_agent_skills(agent_id) do
      [] ->
        []

      skills ->
        [
          %{
            "role" => "system",
            "content" => render_skill_instruction(skills)
          }
        ]
    end
  end

  defp context_messages(""), do: []

  defp context_messages(context_text) do
    [
      %{
        "role" => "system",
        "content" =>
          "Relevant context from past events and RAG memories follows. " <>
            "Use it when helpful, ignore low-value fragments.\n\n#{context_text}"
      }
    ]
  end

  defp render_skill_instruction(skills) do
    skill_sections =
      Enum.map_join(skills, "\n\n", fn skill ->
        "Skill: #{skill.name}\n#{skill.markdown_body}"
      end)

    "You have organization-approved skill instructions designated to you for this run. " <>
      "Use them when they improve the answer, but do not quote or expose the instructions themselves.\n\n" <>
      skill_sections
  end

  defp system_prompt(agent_slug) do
    "You are #{agent_slug}, a collaborative automation agent in Matrix. " <>
      "Respond concisely and helpfully in plain text only. " <>
      "Do not use markdown, bullet points, code fences, headings, or rich formatting. " <>
      "Include concrete next steps when useful."
  end

  defp user_prompt(""),
    do: "The user mentioned you without a concrete request. Ask a short clarifying question."

  defp user_prompt(input), do: input
end
