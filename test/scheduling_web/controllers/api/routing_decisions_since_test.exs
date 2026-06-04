defmodule SchedulingWeb.Api.RoutingDecisionsSinceTest do
  @moduledoc """
  Coverage for the `?since=<iso8601>` query parameter on
  GET /api/v1/routing_decisions.
  """
  use SchedulingWeb.ConnCase, async: true

  alias Scheduling.Audit.RoutingDecision
  alias Scheduling.Repo

  defp decision_at(ts) do
    Repo.insert!(%RoutingDecision{
      rationale: "test",
      required_capabilities: [],
      eligible_offices: [],
      inserted_at: ts,
      updated_at: ts
    })
  end

  test "returns only decisions with inserted_at >= since", %{conn: conn} do
    old = decision_at(~U[2026-01-01 00:00:00Z])
    new = decision_at(~U[2026-06-01 00:00:00Z])

    since = "2026-03-01T00:00:00Z"
    conn = get(conn, ~p"/api/v1/routing_decisions?since=#{since}")
    body = json_response(conn, 200)

    ids = Enum.map(body, & &1["id"])
    assert new.id in ids
    refute old.id in ids
  end

  test "?since=invalid is ignored", %{conn: conn} do
    decision_at(~U[2026-06-01 00:00:00Z])

    conn = get(conn, ~p"/api/v1/routing_decisions?since=garbage")
    assert is_list(json_response(conn, 200))
  end
end
