defmodule SchedulingWeb.HealthController do
  use SchedulingWeb, :controller

  alias Scheduling.Repo

  def index(conn, _params) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} ->
        conn |> put_status(:ok) |> json(%{status: "ok"})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{status: "degraded"})
    end
  end
end
