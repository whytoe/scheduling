defmodule SchedulingWeb.PageControllerTest do
  use SchedulingWeb.ConnCase

  test "GET / redirects to /board", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == ~p"/board"
  end
end
