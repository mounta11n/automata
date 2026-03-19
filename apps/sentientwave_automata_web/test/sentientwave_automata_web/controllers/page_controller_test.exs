defmodule SentientwaveAutomataWeb.PageControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  import Plug.Test, only: [init_test_session: 2]

  alias SentientwaveAutomata.Agents

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "GET / redirects to dashboard when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/")

    assert redirected_to(conn) == "/dashboard"
  end

  test "GET /dashboard renders dashboard when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/dashboard")

    assert html_response(conn, 200) =~ "Admin Dashboard"
  end

  test "GET /settings/llm renders llm page when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm")

    assert html_response(conn, 200) =~ "LLM Provider Management"
  end

  test "GET /settings/tools renders tools page when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/tools")

    assert html_response(conn, 200) =~ "Tool Management"
  end

  test "GET /observability/llm-traces renders trace explorer when authenticated", %{conn: conn} do
    assert {:ok, _trace} =
             Agents.create_llm_trace(%{
               provider: "local",
               model: "local-default",
               call_kind: "response",
               sequence_index: 0,
               status: "ok",
               requester_kind: "person",
               requester_mxid: "@mio:localhost",
               room_id: "!room:localhost",
               conversation_scope: "room",
               request_payload: %{"messages" => [%{"role" => "user", "content" => "hello"}]},
               response_payload: %{"content" => "hi"},
               requested_at: DateTime.utc_now()
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/observability/llm-traces", %{"filters" => %{"q" => "hello"}})

    body = html_response(conn, 200)
    assert body =~ "LLM Trace Explorer"
    assert body =~ "@mio:localhost"
  end

  test "GET /observability/llm-traces/:id renders trace detail when authenticated", %{conn: conn} do
    assert {:ok, trace} =
             Agents.create_llm_trace(%{
               provider: "openai",
               model: "gpt-4o-mini",
               call_kind: "tool_planner",
               sequence_index: 0,
               status: "error",
               requester_kind: "agent",
               requester_mxid: "@automata:localhost",
               room_id: "!ops:localhost",
               conversation_scope: "private_message",
               request_payload: %{
                 "messages" => [%{"role" => "user", "content" => "search weather"}]
               },
               error_payload: %{"reason" => "missing_api_key"},
               requested_at: DateTime.utc_now()
             })

    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/observability/llm-traces/#{trace.id}")

    body = html_response(conn, 200)
    assert body =~ "LLM Trace Detail"
    assert body =~ "missing_api_key"
    assert body =~ "gpt-4o-mini"
  end
end
