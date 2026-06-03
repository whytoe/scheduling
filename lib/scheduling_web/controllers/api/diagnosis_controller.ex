defmodule SchedulingWeb.Api.DiagnosisController do
  @moduledoc """
  JSON API for the diagnosis catalog. Each diagnosis carries a default set of
  required capabilities (its capability_ids) which queue entries inherit.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Catalog
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags ["diagnoses"]

  operation :index,
    summary: "List diagnoses",
    responses: [ok: {"Diagnoses", "application/json", Schemas.DiagnosisList}]

  def index(conn, _params) do
    json(conn, Enum.map(Catalog.list_diagnoses(), &serialize/1))
  end

  operation :show,
    summary: "Get one diagnosis",
    parameters: [id: [in: :path, description: "Diagnosis id", type: :integer]],
    responses: [
      ok: {"Diagnosis", "application/json", Schemas.Diagnosis},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, diagnosis} <- fetch(id) do
      json(conn, serialize(diagnosis))
    end
  end

  operation :create,
    summary: "Create a diagnosis",
    request_body: {"Diagnosis attrs", "application/json", Schemas.DiagnosisRequest},
    responses: [
      created: {"Created", "application/json", Schemas.Diagnosis},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]

  def create(conn, %{"diagnosis" => params}) do
    with {:ok, diagnosis} <- Catalog.create_diagnosis(params) do
      conn |> put_status(:created) |> json(serialize(reload(diagnosis)))
    end
  end

  operation :update,
    summary: "Update a diagnosis",
    parameters: [id: [in: :path, description: "Diagnosis id", type: :integer]],
    request_body: {"Diagnosis attrs", "application/json", Schemas.DiagnosisRequest},
    responses: [
      ok: {"Updated", "application/json", Schemas.Diagnosis},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]

  def update(conn, %{"id" => id, "diagnosis" => params}) do
    with {:ok, diagnosis} <- fetch(id),
         {:ok, updated} <- Catalog.update_diagnosis(diagnosis, params) do
      json(conn, serialize(reload(updated)))
    end
  end

  operation :delete,
    summary: "Delete a diagnosis",
    parameters: [id: [in: :path, description: "Diagnosis id", type: :integer]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]

  def delete(conn, %{"id" => id}) do
    with {:ok, diagnosis} <- fetch(id),
         {:ok, _} <- Catalog.delete_diagnosis(diagnosis) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Catalog.get_diagnosis!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp reload(diagnosis), do: Catalog.get_diagnosis!(diagnosis.id)

  defp serialize(diagnosis) do
    %{
      id: diagnosis.id,
      name: diagnosis.name,
      code: diagnosis.code,
      capabilities: Enum.map(diagnosis.capabilities, &serialize_capability/1),
      inserted_at: diagnosis.inserted_at,
      updated_at: diagnosis.updated_at
    }
  end

  defp serialize_capability(capability) do
    %{
      id: capability.id,
      name: capability.name,
      description: capability.description,
      inserted_at: capability.inserted_at,
      updated_at: capability.updated_at
    }
  end
end
