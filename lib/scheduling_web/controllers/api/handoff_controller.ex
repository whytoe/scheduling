defmodule SchedulingWeb.Api.HandoffController do
  @moduledoc """
  JSON API for incoming-patient handoffs. Created automatically when a queue
  entry is accepted into an office; this API lets office staff list and
  acknowledge them.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Handoffs
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags ["handoffs"]

  operation :index,
    summary: "List pending handoffs",
    description: "Returns pending handoffs. Pass `?office_id=N` to scope to one office.",
    parameters: [
      office_id: [
        in: :query,
        description: "Optional office id to filter by",
        type: :integer,
        required: false
      ]
    ],
    responses: [ok: {"Handoffs", "application/json", Schemas.HandoffList}]

  def index(conn, params) do
    handoffs =
      case Map.get(params, "office_id") do
        nil ->
          Handoffs.list_pending()

        id ->
          case Integer.parse(to_string(id)) do
            {int_id, ""} -> Handoffs.list_pending_for_office(int_id)
            _ -> []
          end
      end

    json(conn, Enum.map(handoffs, &serialize/1))
  end

  operation :show,
    summary: "Get one handoff",
    parameters: [id: [in: :path, description: "Handoff id", type: :integer]],
    responses: [
      ok: {"Handoff", "application/json", Schemas.Handoff},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, handoff} <- fetch(id) do
      json(conn, serialize(handoff))
    end
  end

  operation :acknowledge,
    summary: "Acknowledge a pending handoff",
    description: "Marks a pending handoff as acknowledged, stamping the time and (optionally) the user.",
    parameters: [id: [in: :path, description: "Handoff id", type: :integer]],
    request_body:
      {"Acknowledgement attrs", "application/json", Schemas.HandoffAcknowledgeRequest,
       required: false},
    responses: [
      ok: {"Acknowledged", "application/json", Schemas.Handoff},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Already acknowledged or invalid", "application/json", Schemas.ValidationError}
    ]

  def acknowledge(conn, %{"id" => id} = params) do
    opts =
      case Map.get(params, "acknowledged_by") do
        nil -> []
        by -> [acknowledged_by: by]
      end

    with {:ok, handoff} <- fetch(id),
         {:ok, acked} <- Handoffs.acknowledge(handoff, opts) do
      json(conn, serialize(acked))
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Handoffs.get_handoff!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp serialize(h) do
    %{
      id: h.id,
      status: h.status,
      patient_name: h.patient_name,
      office_name: h.office_name,
      required_capabilities: h.required_capabilities,
      acknowledged_at: h.acknowledged_at,
      acknowledged_by: h.acknowledged_by,
      office_id: h.office_id,
      patient_id: h.patient_id,
      queue_entry_id: h.queue_entry_id,
      inserted_at: h.inserted_at,
      updated_at: h.updated_at
    }
  end
end
