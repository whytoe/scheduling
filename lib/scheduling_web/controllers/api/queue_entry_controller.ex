defmodule SchedulingWeb.Api.QueueEntryController do
  @moduledoc """
  JSON API for the patient queue: list, show, create, and the lifecycle
  actions (`accept`, `complete`, `requeue`). The accept action is what runs
  the matcher and assigns the patient to a best-fit office.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Catalog
  alias Scheduling.Queue
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags ["queue"]

  operation :index,
    summary: "List queue entries",
    description:
      "By default lists waiting entries (highest priority first). Pass " <>
        "`?status=active` for entries currently consuming office capacity " <>
        "(`assigned`/`in_service`), or `?status=all` for both.",
    parameters: [
      status: [
        in: :query,
        description: "`waiting` (default), `active`, or `all`",
        type: :string,
        required: false
      ]
    ],
    responses: [ok: {"Queue entries", "application/json", Schemas.QueueEntryList}]

  def index(conn, params) do
    entries =
      case Map.get(params, "status", "waiting") do
        "active" -> Queue.list_active_entries()
        "all" -> Queue.list_waiting_entries() ++ Queue.list_active_entries()
        _ -> Queue.list_waiting_entries()
      end

    json(conn, Enum.map(entries, &serialize/1))
  end

  operation :show,
    summary: "Get one queue entry",
    parameters: [id: [in: :path, description: "Queue entry id", type: :integer]],
    responses: [
      ok: {"Queue entry", "application/json", Schemas.QueueEntry},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, entry} <- fetch(id) do
      json(conn, serialize(entry))
    end
  end

  operation :create,
    summary: "Create a queue entry",
    description:
      "Adds a patient to the waiting queue. The matcher does NOT run here — " <>
        "call `POST /queue_entries/:id/accept` to assign the entry to an office.",
    request_body: {"Queue entry attrs", "application/json", Schemas.QueueEntryCreateRequest},
    responses: [
      created: {"Created", "application/json", Schemas.QueueEntry},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]

  def create(conn, %{"queue_entry" => params}) do
    with {:ok, entry} <- Queue.create_entry(params) do
      conn |> put_status(:created) |> json(serialize(entry))
    end
  end

  operation :accept,
    summary: "Accept a waiting entry into an office",
    description:
      "Runs the compliance check (intake forms required by the diagnosis), " <>
        "then the best-fit matcher over the entry's required capabilities and " <>
        "current office loads. On success the entry is assigned, the audit log " <>
        "records the decision, and a handoff is created for the office's " <>
        "clinical staff.\n\n" <>
        "Failure modes:\n" <>
        "  * 409 `no_eligible_office` — no office both provides the required " <>
        "capabilities and has free capacity.\n" <>
        "  * 422 `compliance_failed` — the patient hasn't completed every required " <>
        "form (response body lists the missing form types). The entry stays waiting.\n" <>
        "  * 503 `compliance_unavailable` — intake-form system unreachable. " <>
        "Fail-closed: the booking is blocked until intake recovers.",
    parameters: [id: [in: :path, description: "Queue entry id", type: :integer]],
    request_body:
      {"Accept attrs (optional)", "application/json", Schemas.QueueEntryAcceptRequest,
       required: false},
    responses: [
      ok: {"Assigned", "application/json", Schemas.QueueEntry},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      conflict: {"No eligible office", "application/json", Schemas.NoEligibleOfficeError},
      unprocessable_entity:
        {"Compliance failed or validation error", "application/json", Schemas.ComplianceFailedError},
      service_unavailable:
        {"Intake-form system unreachable", "application/json", Schemas.ComplianceUnavailableError}
    ]

  def accept(conn, %{"id" => id} = params) do
    opts =
      case Map.get(params, "accepted_by") do
        nil -> []
        by -> [accepted_by: by]
      end

    with {:ok, entry} <- fetch(id) do
      case Queue.accept(entry, opts) do
        {:ok, assigned, _result} ->
          json(conn, serialize(reload(assigned)))

        {:no_eligible_office, _result} ->
          conn |> put_status(:conflict) |> json(%{error: "no_eligible_office"})

        {:compliance_failed, missing_types} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "compliance_failed", missing_form_types: missing_types})

        {:compliance_unavailable, reason} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "compliance_unavailable", reason: inspect(reason)})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
    end
  end

  operation :complete,
    summary: "Complete an in-service entry",
    description: "Transitions the entry to `:completed` and frees the assigned office's intake capacity.",
    parameters: [id: [in: :path, description: "Queue entry id", type: :integer]],
    responses: [
      ok: {"Completed", "application/json", Schemas.QueueEntry},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]

  def complete(conn, %{"id" => id}) do
    with {:ok, entry} <- fetch(id),
         {:ok, completed} <- Queue.complete(entry) do
      json(conn, serialize(reload(completed)))
    end
  end

  operation :requeue,
    summary: "Re-queue an active entry",
    description:
      "Returns the entry to `:waiting`, freeing its assigned office's " <>
        "capacity. Pass `required_capability_ids` to swap the patient's " <>
        "required capabilities (e.g. they're being routed for a different " <>
        "service this time).",
    parameters: [id: [in: :path, description: "Queue entry id", type: :integer]],
    request_body:
      {"Requeue attrs (optional)", "application/json", Schemas.QueueEntryRequeueRequest,
       required: false},
    responses: [
      ok: {"Requeued", "application/json", Schemas.QueueEntry},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]

  def requeue(conn, %{"id" => id} = params) do
    opts =
      case Map.get(params, "required_capability_ids") do
        nil ->
          []

        ids ->
          caps =
            ids
            |> List.wrap()
            |> Enum.reject(&(&1 in [nil, ""]))
            |> Enum.map(&Catalog.get_capability!/1)

          [required_capabilities: caps]
      end

    with {:ok, entry} <- fetch(id),
         {:ok, requeued} <- Queue.requeue(entry, opts) do
      json(conn, serialize(reload(requeued)))
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Queue.get_entry!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp reload(entry), do: Queue.get_entry!(entry.id)

  defp serialize(entry) do
    %{
      id: entry.id,
      status: entry.status,
      priority: entry.priority,
      patient_id: entry.patient_id,
      diagnosis_id: entry.diagnosis_id,
      assigned_office_id: entry.assigned_office_id,
      visit_id: entry.visit_id,
      patient: serialize_patient(entry.patient),
      required_capabilities: serialize_capabilities(entry.required_capabilities),
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at
    }
  end

  defp serialize_patient(%Ecto.Association.NotLoaded{}), do: nil
  defp serialize_patient(nil), do: nil

  defp serialize_patient(p) do
    %{
      id: p.id,
      name: p.name,
      client_id: p.client_id,
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
