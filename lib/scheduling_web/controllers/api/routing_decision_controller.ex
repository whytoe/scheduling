defmodule SchedulingWeb.Api.RoutingDecisionController do
  @moduledoc """
  Read-only JSON API for the routing-decision audit log. The accept flow
  writes one row here every time the matcher runs; this controller never
  mutates the log.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Audit
  alias SchedulingWeb.Pagination
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags(["routing_decisions"])

  operation(:index,
    summary: "List routing decisions",
    description:
      "Most recent first. Each row captures the matcher inputs (required " <>
        "capabilities, eligible offices), the chosen office (or none), and " <>
        "the human-readable rationale.\n\n" <>
        "**Incremental polling**: `?since=<iso8601>` returns rows with " <>
        "`inserted_at >= since`, inclusive.\n\n" <>
        "**Pagination**: `?limit=N&after=<id>`. Default 100, max 500. " <>
        "Response carries `X-Next-Cursor` until the listing is exhausted.",
    parameters: [
      since: [
        in: :query,
        type: :string,
        required: false,
        description: "ISO-8601 timestamp; returns decisions with inserted_at >= since"
      ],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description: "Page size, default 100, max 500"
      ],
      after: [
        in: :query,
        type: :integer,
        required: false,
        description: "Cursor: id of the last row from the previous page"
      ]
    ],
    responses: [ok: {"Routing decisions", "application/json", Schemas.RoutingDecisionList}]
  )

  def index(conn, params) do
    filters =
      case Map.get(params, "since") do
        nil ->
          %{}

        v ->
          case DateTime.from_iso8601(to_string(v)) do
            {:ok, dt, _} -> %{since: dt}
            _ -> %{}
          end
      end

    pagination = Pagination.parse(params)

    {page, next_cursor} =
      filters
      |> Audit.decisions_query()
      |> Pagination.apply(pagination)
      |> Scheduling.Repo.all()
      |> Scheduling.Repo.preload([:patient, :chosen_office, :queue_entry])
      |> Pagination.slice(pagination.limit)

    conn
    |> Pagination.put_next_cursor(next_cursor)
    |> json(Enum.map(page, &serialize/1))
  end

  operation(:show,
    summary: "Get one routing decision",
    parameters: [id: [in: :path, description: "Routing decision id", type: :integer]],
    responses: [
      ok: {"Routing decision", "application/json", Schemas.RoutingDecision},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]
  )

  def show(conn, %{"id" => id}) do
    with {:ok, decision} <- fetch(id) do
      json(conn, serialize(decision))
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Audit.get_decision!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp serialize(d) do
    %{
      id: d.id,
      patient_name: d.patient_name,
      chosen_office_name: d.chosen_office_name,
      required_capabilities: d.required_capabilities,
      eligible_offices: d.eligible_offices,
      rationale: d.rationale,
      accepted_by: d.accepted_by,
      patient_id: d.patient_id,
      chosen_office_id: d.chosen_office_id,
      queue_entry_id: d.queue_entry_id,
      inserted_at: d.inserted_at,
      updated_at: d.updated_at
    }
  end
end
