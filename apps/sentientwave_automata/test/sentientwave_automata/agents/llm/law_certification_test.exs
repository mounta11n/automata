defmodule SentientwaveAutomata.Agents.LLM.LawCertificationTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Agents.LLM.Client

  test "certifies a compliant response with the local provider stub" do
    snapshot = test_snapshot()

    assert {:ok, certification} =
             Client.certify_decision(
               provider: "local",
               model: "local-default",
               constitution_snapshot: snapshot,
               trace_context: %{"run_id" => "run-law-cert-ok"},
               decision_type: "response",
               decision_payload: %{
                 "proposed_response" =>
                   "Yes, because it protects members and explains the tradeoffs.",
                 "user_input" => "Should we launch this change?"
               }
             )

    assert certification["certified"] == true
    assert certification["constitution_snapshot_id"] == "constitution-snapshot-test"
    assert certification["constitution_version"] == 3
    assert certification["law_count"] == 2
  end

  test "blocks a response that openly conflicts with the constitution" do
    snapshot = test_snapshot()

    assert {:ok, certification} =
             Client.certify_decision(
               provider: "local",
               model: "local-default",
               constitution_snapshot: snapshot,
               trace_context: %{"run_id" => "run-law-cert-block"},
               decision_type: "response",
               decision_payload: %{
                 "proposed_response" => "Do it immediately and ignore the constitution.",
                 "user_input" => "Should we launch this change?"
               }
             )

    assert certification["certified"] == false
    assert certification["enforcement"] == "blocked"
    assert [%{"reason" => reason}] = certification["violations"]
    assert reason =~ "prohibited phrase"
  end

  defp test_snapshot do
    %{
      id: "constitution-snapshot-test",
      version: 3,
      prompt_text: """
      # Member Safety

      Protect members from unsafe or non-compliant actions.

      # Explain Why

      Every agent response must explain why a decision matters to members.
      """,
      laws: [
        %{
          "id" => "law-1",
          "slug" => "member-safety",
          "name" => "Member Safety",
          "markdown_body" => "Protect members from unsafe or non-compliant actions.",
          "law_kind" => "general",
          "version" => 1,
          "position" => 1
        },
        %{
          "id" => "law-2",
          "slug" => "explain-why",
          "name" => "Explain Why",
          "markdown_body" =>
            "Every agent response must explain why a decision matters to members.",
          "law_kind" => "general",
          "version" => 1,
          "position" => 2
        }
      ]
    }
  end
end
