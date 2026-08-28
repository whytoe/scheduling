defmodule SchedulingWeb.HealthController do
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Repo
  alias SchedulingWeb.Schemas

  tags(["health"])

  operation(:index,
    summary: "Health check",
    description:
      "Returns `200 {\"status\":\"ok\"}` when the app is up and `SELECT 1` " <>
        "against the database succeeded; `503 {\"status\":\"degraded\"}` when " <>
        "the database is unreachable. Suitable as both a liveness and a " <>
        "readiness probe.",
    # Overrides the document-level bearer requirement: a liveness probe that
    # needs a token is a liveness probe that reports the IdP's health too.
    security: [],
    responses: [
      ok: {"App is healthy", "application/json", Schemas.HealthResponse},
      service_unavailable: {"Database unreachable", "application/json", Schemas.HealthResponse}
    ]
  )

  def index(conn, _params) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} ->
        conn |> put_status(:ok) |> json(%{status: "ok"})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "degraded"})
    end
  end
end
