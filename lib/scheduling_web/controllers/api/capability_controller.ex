defmodule SchedulingWeb.Api.CapabilityController do
  @moduledoc """
  JSON API for the capability catalog. Read, create, update, and delete the
  labels (XRay, Computed Tomography (CT), Dialysis…) that offices declare and
  queue entries require.
  """
  use SchedulingWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Scheduling.Catalog
  alias SchedulingWeb.Schemas

  action_fallback SchedulingWeb.Api.FallbackController

  tags ["capabilities"]

  operation :index,
    summary: "List capabilities",
    description: "Returns every capability in the catalog, sorted by name.",
    responses: [
      ok: {"Capabilities", "application/json", Schemas.CapabilityList}
    ]

  def index(conn, _params) do
    capabilities = Catalog.list_capabilities()
    json(conn, Enum.map(capabilities, &serialize/1))
  end

  operation :show,
    summary: "Get one capability",
    parameters: [id: [in: :path, description: "Capability id", type: :integer, example: 1]],
    responses: [
      ok: {"Capability", "application/json", Schemas.Capability},
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]

  def show(conn, %{"id" => id}) do
    with {:ok, capability} <- fetch(id) do
      json(conn, serialize(capability))
    end
  end

  operation :create,
    summary: "Create a capability",
    request_body: {"Capability attrs", "application/json", Schemas.CapabilityRequest},
    responses: [
      created: {"Created", "application/json", Schemas.Capability},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]

  def create(conn, %{"capability" => params}) do
    with {:ok, capability} <- Catalog.create_capability(params) do
      conn |> put_status(:created) |> json(serialize(capability))
    end
  end

  operation :update,
    summary: "Update a capability",
    parameters: [id: [in: :path, description: "Capability id", type: :integer, example: 1]],
    request_body: {"Capability attrs", "application/json", Schemas.CapabilityRequest},
    responses: [
      ok: {"Updated", "application/json", Schemas.Capability},
      not_found: {"Not found", "application/json", Schemas.NotFoundError},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.ValidationError}
    ]

  def update(conn, %{"id" => id, "capability" => params}) do
    with {:ok, capability} <- fetch(id),
         {:ok, updated} <- Catalog.update_capability(capability, params) do
      json(conn, serialize(updated))
    end
  end

  operation :delete,
    summary: "Delete a capability",
    description:
      "Cascades through `office_capabilities`, `diagnosis_capabilities`, and " <>
        "`queue_entry_capabilities` (all FKs are `on_delete: :delete_all`) so " <>
        "the capability is removed from every office, diagnosis default, and " <>
        "pending queue requirement that referenced it.",
    parameters: [id: [in: :path, description: "Capability id", type: :integer, example: 1]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.NotFoundError}
    ]

  def delete(conn, %{"id" => id}) do
    with {:ok, capability} <- fetch(id),
         {:ok, _} <- Catalog.delete_capability(capability) do
      send_resp(conn, :no_content, "")
    end
  end

  defp fetch(id) do
    case Integer.parse(to_string(id)) do
      {int_id, ""} ->
        try do
          {:ok, Catalog.get_capability!(int_id)}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp serialize(capability) do
    %{
      id: capability.id,
      name: capability.name,
      description: capability.description,
      inserted_at: capability.inserted_at,
      updated_at: capability.updated_at
    }
  end
end
