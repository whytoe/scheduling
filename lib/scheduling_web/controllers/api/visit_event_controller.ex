defmodule SchedulingWeb.Api.VisitEventController do
  @moduledoc """
  Read-only JSON API for the visit-lifecycle event log. Sibling to
  /api/routing_decisions; together they form the audit timeline. Filter by
  visit / queue_entry / patient / handoff / type / actor to scope.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Audit
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags ["visit_events"]

  operation :index,
    summary: "List visit events",
    description:
      "Most recent first. Query parameters scope the result; pass none to get " <>
        "the whole log. Use `since=<iso8601>` for incremental polling — the " <>
        "filter is `occurred_at >= since`, inclusive, so a consumer can carry " <>
        "forward the most-recent `occurred_at` from the previous response.",
    parameters: [
      visit_id: [in: :query, type: :integer, required: false],
      queue_entry_id: [in: :query, type: :integer, required: false],
      patient_id: [in: :query, type: :integer, required: false],
      handoff_id: [in: :query, type: :integer, required: false],
      type: [in: :query, type: :string, required: false],
      actor_type: [in: :query, type: :string, required: false],
      actor_id: [in: :query, type: :string, required: false],
      since: [
        in: :query,
        type: :string,
        required: false,
        description: "ISO-8601 timestamp (e.g. 2026-06-01T12:00:00Z); returns events with occurred_at >= since"
      ]
    ],
    responses: [ok: {"Visit events", "application/json", Schemas.VisitEventList}]

  def index(conn, params) do
    filters = build_filters(params)
    json(conn, Enum.map(Audit.list_events(filters), &serialize/1))
  end

  operation :show,
    summary: "Get one visit event",
    parameters: [id: [in: :path, type: :integer]],
    responses: [
      ok: {"Visit event", "application/json", Schemas.VisitEvent},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, event} <- fetch(id) do
      json(conn, serialize(event))
    end
  end

  defp build_filters(params) do
    [
      visit_id: parse_int(params, "visit_id"),
      queue_entry_id: parse_int(params, "queue_entry_id"),
      patient_id: parse_int(params, "patient_id"),
      handoff_id: parse_int(params, "handoff_id"),
      type: Map.get(params, "type"),
      actor_type: Map.get(params, "actor_type"),
      actor_id: Map.get(params, "actor_id"),
      since: parse_iso8601(params, "since")
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_int(params, key) do
    case Map.get(params, key) do
      nil ->
        nil

      v ->
        case Integer.parse(to_string(v)) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  defp parse_iso8601(params, key) do
    case Map.get(params, key) do
      nil ->
        nil

      v ->
        case DateTime.from_iso8601(to_string(v)) do
          {:ok, dt, _offset} -> dt
          {:error, _} -> nil
        end
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Audit.get_event!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp serialize(e) do
    %{
      id: e.id,
      type: e.type,
      visit_id: e.visit_id,
      queue_entry_id: e.queue_entry_id,
      patient_id: e.patient_id,
      handoff_id: e.handoff_id,
      actor_type: e.actor_type,
      actor_id: e.actor_id,
      payload: e.payload || %{},
      occurred_at: e.occurred_at,
      inserted_at: e.inserted_at,
      updated_at: e.updated_at
    }
  end
end
