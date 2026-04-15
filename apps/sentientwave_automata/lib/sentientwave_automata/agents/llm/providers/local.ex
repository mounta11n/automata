defmodule SentientwaveAutomata.Agents.LLM.Providers.Local do
  @moduledoc false

  @behaviour SentientwaveAutomata.Agents.LLMProvider

  @impl true
  def complete(messages, _opts \\ []) when is_list(messages) do
    if certification_prompt?(messages) do
      {:ok, certification_response(messages)}
    else
      user_text =
        messages
        |> Enum.reverse()
        |> Enum.find_value("", fn
          %{"role" => "user", "content" => content} when is_binary(content) -> content
          _ -> nil
        end)
        |> String.trim()

      reply =
        if user_text == "" do
          "I am ready. Ask me to summarize, plan, or propose next steps."
        else
          "I received your request: \"#{user_text}\"."
        end

      {:ok, reply}
    end
  end

  defp certification_prompt?(messages) do
    Enum.any?(messages, fn
      %{"role" => "system", "content" => content} when is_binary(content) ->
        String.contains?(content, "governance law compliance certifier")

      _ ->
        false
    end)
  end

  defp certification_response(messages) do
    constitution_text =
      messages
      |> Enum.find_value("", fn
        %{"role" => "system", "content" => content} when is_binary(content) ->
          if String.contains?(content, "Company constitution and governance laws") do
            content
          end

        _ ->
          nil
      end)
      |> String.trim()

    decision_payload =
      messages
      |> Enum.reverse()
      |> Enum.find_value(%{}, fn
        %{"role" => "user", "content" => content} when is_binary(content) ->
          case Jason.decode(content) do
            {:ok, payload} -> payload
            _ -> nil
          end

        _ ->
          nil
      end)

    certification =
      case decision_payload do
        %{"decision_type" => "response", "decision" => %{"proposed_response" => response}} ->
          build_response_certification(constitution_text, decision_payload, response)

        _ ->
          %{
            "certified" => false,
            "summary" => "The local certification stub could not parse the proposed decision.",
            "violations" => [
              %{
                "law_name" => "Current Constitution",
                "reason" => "The proposed decision payload was invalid."
              }
            ]
          }
      end

    Jason.encode!(certification)
  end

  defp build_response_certification(constitution_text, decision_payload, response) do
    normalized_response = response |> to_string() |> String.trim()
    normalized_laws = Map.get(decision_payload, "laws", [])
    explain_why_required? = constitution_requires_explanation?(constitution_text, normalized_laws)
    blocked_phrase = blocked_phrase(normalized_response)

    cond do
      String.trim(constitution_text) == "" and normalized_laws == [] ->
        %{
          "certified" => false,
          "summary" => "No published constitution snapshot is available for certification.",
          "violations" => [
            %{
              "law_name" => "Current Constitution",
              "reason" => "No published constitution snapshot is available for certification."
            }
          ]
        }

      normalized_response == "" ->
        %{
          "certified" => false,
          "summary" => "The proposed response is empty and could not be certified.",
          "violations" => [
            %{
              "law_name" => "Current Constitution",
              "reason" => "The proposed response was empty."
            }
          ]
        }

      blocked_phrase != nil ->
        %{
          "certified" => false,
          "summary" =>
            "The proposed response explicitly conflicts with the current constitution.",
          "violations" => [
            %{
              "law_name" => "Current Constitution",
              "reason" => "The response contains a prohibited phrase: #{blocked_phrase}."
            }
          ]
        }

      explain_why_required? and not explanatory_response?(normalized_response) ->
        law = find_explanation_law(normalized_laws)

        %{
          "certified" => false,
          "summary" => "The proposed response does not explain why the decision matters.",
          "violations" => [
            %{
              "law_slug" => law && Map.get(law, "slug"),
              "law_name" => law && Map.get(law, "name", "Explain Why"),
              "reason" =>
                "The response did not include an explanation of why the decision matters."
            }
          ]
        }

      true ->
        %{
          "certified" => true,
          "summary" => "The proposed response satisfies the current constitution.",
          "violations" => []
        }
    end
  end

  defp constitution_requires_explanation?(constitution_text, laws) do
    text =
      [constitution_text | Enum.map(laws, &Map.get(&1, "prompt_text", ""))]
      |> Enum.join("\n")
      |> String.downcase()

    String.contains?(text, "explain why") or
      String.contains?(text, "why a decision matters") or
      String.contains?(text, "why it matters")
  end

  defp find_explanation_law(laws) do
    Enum.find(laws, fn law ->
      text =
        [
          Map.get(law, "name", ""),
          Map.get(law, "markdown_body", ""),
          Map.get(law, "prompt_text", "")
        ]
        |> Enum.join("\n")
        |> String.downcase()

      String.contains?(text, "explain why") or
        String.contains?(text, "why a decision matters") or
        String.contains?(text, "why it matters")
    end)
  end

  defp explanatory_response?(response) do
    downcased = String.downcase(response)
    String.contains?(downcased, "because") or String.contains?(downcased, "so that")
  end

  defp blocked_phrase(response) do
    Enum.find(
      [
        "ignore the constitution",
        "break the law",
        "violate the law",
        "disobey the law",
        "ignore the rules"
      ],
      &String.contains?(String.downcase(response), &1)
    )
  end
end
