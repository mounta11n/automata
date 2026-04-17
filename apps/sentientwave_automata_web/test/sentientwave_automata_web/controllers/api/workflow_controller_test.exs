defmodule SentientwaveAutomataWeb.API.WorkflowControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  test "requires service auth when token is configured", %{conn: conn} do
    previous = System.get_env("AUTOMATA_API_TOKEN")
    System.put_env("AUTOMATA_API_TOKEN", "test-service-token")

    on_exit(fn ->
      if previous do
        System.put_env("AUTOMATA_API_TOKEN", previous)
      else
        System.delete_env("AUTOMATA_API_TOKEN")
      end
    end)

    conn =
      post(conn, ~p"/api/v1/workflows", %{
        "room_id" => "!ops:localhost",
        "objective" => "Triage",
        "requested_by" => "@ops:localhost"
      })

    assert json_response(conn, 401)["error"] == "service_auth_required"
  end
end
