defmodule SchedulingWeb.Api.VisitController do
  @moduledoc """
  JSON API for visits — the patient-encounter parent that spans potentially
  multiple queue entries.

  The check-in / queueing service creates a visit when the patient signs
  in; subsequent queue entries (including those produced by downstream
  disposition) reference the same `visit_id`. Closing a visit is
  idempotent.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Visits
  alias SchedulingWeb.Api.Actor
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags(["visits"])

  operation(:index,
    summary: "List visits",
    description: "Returns visits most-recent-first.",
    responses: [ok: {"Visits", "application/json", Schemas.VisitList}]
  )

  def index(conn, _params) do
    json(conn, Enum.map(Visits.list_visits(), &serialize/1))
  end

  operation(:show,
    summary: "Get one visit",
    parameters: [id: [in: :path, description: "Visit id", type: :integer]],
    responses: [
      ok: {"Visit", "application/json", Schemas.Visit},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]
  )

  def show(conn, %{"id" => id}) do
    with {:ok, visit} <- fetch(id) do
      json(conn, serialize(visit))
    end
  end

  operation(:create,
    summary: "Create a visit (sign-in)",
    description:
      "Called by the check-in / queueing service when a patient signs in. " <>
        "`started_at` defaults to now if omitted. Queue entries for this " <>
        "encounter then reference the returned visit id.",
    request_body: {"Visit attrs", "application/json", Schemas.VisitRequest},
    responses: [
      created: {"Created", "application/json", Schemas.Visit},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]
  )

  def create(conn, %{"visit" => params} = body) do
    with {:ok, visit} <- Visits.create_visit(params, Actor.opts(conn, body)) do
      conn |> put_status(:created) |> json(serialize(visit))
    end
  end

  operation(:end_visit,
    summary: "End a visit",
    description:
      "Stamps `status=ended` and `ended_at=now`. Idempotent on an already-ended visit.",
    parameters: [id: [in: :path, description: "Visit id", type: :integer]],
    responses: [
      ok: {"Ended", "application/json", Schemas.Visit},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]
  )

  def end_visit(conn, %{"id" => id} = body) do
    with {:ok, visit} <- fetch(id),
         {:ok, ended} <- Visits.end_visit(visit, Actor.opts(conn, body)) do
      json(conn, serialize(ended))
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Visits.get_visit!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp serialize(v) do
    %{
      id: v.id,
      patient_id: v.patient_id,
      status: v.status,
      started_at: v.started_at,
      ended_at: v.ended_at,
      inserted_at: v.inserted_at,
      updated_at: v.updated_at
    }
  end
end
