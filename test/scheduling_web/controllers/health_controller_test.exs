defmodule SchedulingWeb.HealthControllerTest do
  use SchedulingWeb.ConnCase, async: true

  test "GET /api/health returns ok when the database is reachable", %{conn: conn} do
    conn = get(conn, ~p"/api/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
