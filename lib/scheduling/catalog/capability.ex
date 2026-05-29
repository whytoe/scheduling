defmodule Scheduling.Catalog.Capability do
  @moduledoc """
  A service or equipment type that an office can provide and a patient may
  require (e.g. XRay, CT Scan, Lab). This is a catalog table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Offices.Office

  schema "capabilities" do
    field :name, :string
    field :description, :string

    many_to_many :offices, Office, join_through: Scheduling.Offices.OfficeCapability

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(capability, attrs) do
    capability
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name)
  end
end
