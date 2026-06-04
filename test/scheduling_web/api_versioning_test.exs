defmodule SchedulingWeb.ApiVersioningTest do
  @moduledoc """
  Pins the versioning contract: /api/v1/* for resource endpoints, /api/*
  unversioned for discovery + health. Catches accidental moves of the
  unversioned endpoints into the version prefix.
  """
  use SchedulingWeb.ConnCase, async: true

  describe "unversioned endpoints" do
    test "GET /api/health still works at the un-versioned path", %{conn: conn} do
      conn = get(conn, ~p"/api/health")
      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    test "GET /api/openapi.json serves the spec at the un-versioned path", %{conn: conn} do
      conn = get(conn, "/api/openapi.json")
      body = json_response(conn, 200)
      assert body["openapi"] != nil
      assert body["info"]["title"] == "Scheduling API"
    end

    test "OpenAPI spec lists every resource under /api/v1/", %{conn: conn} do
      conn = get(conn, "/api/openapi.json")
      paths = Map.keys(json_response(conn, 200)["paths"])
      versioned = Enum.filter(paths, &String.starts_with?(&1, "/api/v1/"))
      unversioned = Enum.reject(paths, &String.starts_with?(&1, "/api/v1/"))

      assert length(versioned) > 0
      assert Enum.sort(unversioned) == ["/api/health"]
    end
  end

  describe "versioned endpoints" do
    test "GET /api/v1/capabilities returns 200", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/capabilities")
      assert is_list(json_response(conn, 200))
    end

    test "old /api/<resource> URLs no longer resolve", %{conn: conn} do
      conn = get(conn, "/api/capabilities")
      # No route -> Phoenix raises NoRouteError which translates to 404.
      assert response(conn, 404)
    end
  end
end
