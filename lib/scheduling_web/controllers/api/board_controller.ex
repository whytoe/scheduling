defmodule SchedulingWeb.Api.BoardController do
  @moduledoc """
  Single read-only endpoint returning the live board's full state — the
  same data the `/board` LiveView shows, packaged for a polling client.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Handoffs
  alias Scheduling.Offices
  alias Scheduling.Queue
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags ["board"]

  operation :show,
    summary: "Snapshot the live board",
    description:
      "Returns the waiting queue (highest priority first), the entries " <>
        "currently consuming office capacity, every office with its " <>
        "current load and free slots, and all pending handoffs. " <>
        "Server-side render of the same data the `/board` LiveView shows.",
    responses: [ok: {"Board snapshot", "application/json", Schemas.BoardSnapshot}]

  def show(conn, _params) do
    loads = Queue.current_loads()

    payload = %{
      waiting: Enum.map(Queue.list_waiting_entries(), &serialize_entry/1),
      active: Enum.map(Queue.list_active_entries(), &serialize_entry/1),
      offices:
        Enum.map(Offices.list_offices(), fn office ->
          load = Map.get(loads, office.id, 0)
          serialize_office_with_load(office, load)
        end),
      pending_handoffs: Enum.map(Handoffs.list_pending(), &serialize_handoff/1),
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    json(conn, payload)
  end

  defp serialize_entry(e) do
    %{
      id: e.id,
      status: e.status,
      priority: e.priority,
      patient_id: e.patient_id,
      diagnosis_id: e.diagnosis_id,
      assigned_office_id: e.assigned_office_id,
      patient: serialize_patient(e.patient),
      required_capabilities: serialize_capabilities(e.required_capabilities),
      inserted_at: e.inserted_at,
      updated_at: e.updated_at
    }
  end

  defp serialize_office_with_load(o, load) do
    %{
      id: o.id,
      name: o.name,
      intake_capacity: o.intake_capacity,
      capabilities: serialize_capabilities(o.capabilities),
      load: load,
      free: max(o.intake_capacity - load, 0),
      inserted_at: o.inserted_at,
      updated_at: o.updated_at
    }
  end

  defp serialize_handoff(h) do
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

  defp serialize_patient(%Ecto.Association.NotLoaded{}), do: nil
  defp serialize_patient(nil), do: nil

  defp serialize_patient(p) do
    %{
      id: p.id,
      name: p.name,
      external_id: p.external_id,
      intake_patient_id: p.intake_patient_id,
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp serialize_capabilities(%Ecto.Association.NotLoaded{}), do: []

  defp serialize_capabilities(caps) when is_list(caps) do
    Enum.map(caps, fn c ->
      %{
        id: c.id,
        name: c.name,
        description: c.description,
        inserted_at: c.inserted_at,
        updated_at: c.updated_at
      }
    end)
  end
end
