defmodule Scheduling.Offices.OfficeCapability do
  @moduledoc """
  Join table connecting an `Office` to the `Capability` entries it provides.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Catalog.Capability
  alias Scheduling.Offices.Office

  schema "office_capabilities" do
    belongs_to :office, Office
    belongs_to :capability, Capability

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(office_capability, attrs) do
    office_capability
    |> cast(attrs, [:office_id, :capability_id])
    |> validate_required([:office_id, :capability_id])
    |> assoc_constraint(:office)
    |> assoc_constraint(:capability)
    |> unique_constraint([:office_id, :capability_id])
  end
end
