defmodule Scheduling.Catalog do
  @moduledoc """
  The capability and diagnosis catalog. Capabilities (XRay, CT Scan, Dialysis…)
  are the labels offices declare and queue entries require; the matcher reads
  them when routing patients to offices.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Repo
  alias Scheduling.Catalog.Capability

  @doc "Lists the capability catalog ordered by name."
  def list_capabilities do
    Capability
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc "Fetches a capability by id. Raises if missing."
  def get_capability!(id), do: Repo.get!(Capability, id)

  @doc "Creates a capability."
  def create_capability(attrs \\ %{}) do
    %Capability{}
    |> Capability.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a capability."
  def update_capability(%Capability{} = capability, attrs) do
    capability
    |> Capability.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a capability. Foreign keys on `office_capabilities`,
  `diagnosis_capabilities`, and `queue_entry_capabilities` cascade, so the
  capability is removed from every office, diagnosis default, and pending
  queue requirement that referenced it.
  """
  def delete_capability(%Capability{} = capability), do: Repo.delete(capability)

  @doc "Returns a changeset for tracking capability form changes."
  def change_capability(%Capability{} = capability, attrs \\ %{}) do
    Capability.changeset(capability, attrs)
  end
end
