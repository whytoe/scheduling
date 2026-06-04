defmodule SchedulingWeb.Api.PatientController do
  @moduledoc """
  JSON API for the patient roster. Registration is owned by the external
  check-in app, so the fields here are deliberately minimal.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Patients
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags ["patients"]

  operation :index,
    summary: "List patients",
    description:
      "Sorted by name. Pass one of the id filters to look up a single patient by " <>
        "their external identifier — useful for integration services that need to " <>
        "know 'have I created a scheduling patient for this upstream id yet?' " <>
        "Each id column carries a unique index, so a filtered query returns at " <>
        "most one row.",
    parameters: [
      intake_patient_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Intakeform UUID — primary key used by the compliance gate"
      ],
      external_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Check-in / queueing app's patient id"
      ],
      client_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Canonical scheduling-owned UUID"
      ]
    ],
    responses: [ok: {"Patients", "application/json", Schemas.PatientList}]

  def index(conn, params) do
    filters = patient_filters(params)
    json(conn, Enum.map(Patients.list_patients(filters), &serialize/1))
  end

  defp patient_filters(params) do
    [intake_patient_id: "intake_patient_id", external_id: "external_id", client_id: "client_id"]
    |> Enum.reduce(%{}, fn {key, param}, acc ->
      case Map.get(params, param) do
        v when is_binary(v) and v != "" -> Map.put(acc, key, v)
        _ -> acc
      end
    end)
  end

  operation :show,
    summary: "Get one patient",
    parameters: [id: [in: :path, description: "Patient id", type: :integer]],
    responses: [
      ok: {"Patient", "application/json", Schemas.Patient},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, patient} <- fetch(id) do
      json(conn, serialize(patient))
    end
  end

  operation :create,
    summary: "Create a patient",
    request_body: {"Patient attrs", "application/json", Schemas.PatientRequest},
    responses: [
      created: {"Created", "application/json", Schemas.Patient},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]

  def create(conn, %{"patient" => params}) do
    with {:ok, patient} <- Patients.create_patient(params) do
      conn |> put_status(:created) |> json(serialize(patient))
    end
  end

  operation :update,
    summary: "Update a patient",
    parameters: [id: [in: :path, description: "Patient id", type: :integer]],
    request_body: {"Patient attrs", "application/json", Schemas.PatientRequest},
    responses: [
      ok: {"Updated", "application/json", Schemas.Patient},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]

  def update(conn, %{"id" => id, "patient" => params}) do
    with {:ok, patient} <- fetch(id),
         {:ok, updated} <- Patients.update_patient(patient, params) do
      json(conn, serialize(updated))
    end
  end

  operation :delete,
    summary: "Delete a patient",
    description: "Cascades to the patient's queue entries (FK on_delete: :delete_all).",
    parameters: [id: [in: :path, description: "Patient id", type: :integer]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]

  def delete(conn, %{"id" => id}) do
    with {:ok, patient} <- fetch(id),
         {:ok, _} <- Patients.delete_patient(patient) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Patients.get_patient!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp serialize(p) do
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
end
