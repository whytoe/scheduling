defmodule SchedulingWeb.Api.OfficeController do
  @moduledoc """
  JSON API for offices — name, intake capacity, and the capabilities each
  office provides (via `capability_ids` in the request body).
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Offices
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags(["offices"])

  operation(:index,
    summary: "List offices",
    responses: [ok: {"Offices", "application/json", Schemas.OfficeList}]
  )

  def index(conn, _params) do
    json(conn, Enum.map(Offices.list_offices(), &serialize/1))
  end

  operation(:show,
    summary: "Get one office",
    parameters: [id: [in: :path, description: "Office id", type: :integer]],
    responses: [
      ok: {"Office", "application/json", Schemas.Office},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]
  )

  def show(conn, %{"id" => id}) do
    with {:ok, office} <- fetch(id) do
      json(conn, serialize(office))
    end
  end

  operation(:create,
    summary: "Create an office",
    request_body: {"Office attrs", "application/json", Schemas.OfficeRequest},
    responses: [
      created: {"Created", "application/json", Schemas.Office},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]
  )

  def create(conn, %{"office" => params}) do
    with {:ok, office} <- Offices.create_office(params) do
      conn |> put_status(:created) |> json(serialize(reload(office)))
    end
  end

  operation(:update,
    summary: "Update an office",
    parameters: [id: [in: :path, description: "Office id", type: :integer]],
    request_body: {"Office attrs", "application/json", Schemas.OfficeRequest},
    responses: [
      ok: {"Updated", "application/json", Schemas.Office},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]
  )

  def update(conn, %{"id" => id, "office" => params}) do
    with {:ok, office} <- fetch(id),
         {:ok, updated} <- Offices.update_office(office, params) do
      json(conn, serialize(reload(updated)))
    end
  end

  operation(:delete,
    summary: "Delete an office",
    parameters: [id: [in: :path, description: "Office id", type: :integer]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]
  )

  def delete(conn, %{"id" => id}) do
    with {:ok, office} <- fetch(id),
         {:ok, _} <- Offices.delete_office(office) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Offices.get_office!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp reload(office), do: Offices.get_office!(office.id)

  defp serialize(office) do
    %{
      id: office.id,
      name: office.name,
      intake_capacity: office.intake_capacity,
      capabilities: Enum.map(office.capabilities, &serialize_capability/1),
      inserted_at: office.inserted_at,
      updated_at: office.updated_at
    }
  end

  defp serialize_capability(c) do
    %{
      id: c.id,
      name: c.name,
      description: c.description,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end
end
