defmodule Scheduling.Offices.Office do
  @moduledoc """
  A clinic location/room with an intake capacity (how many patients it can
  serve concurrently) and a set of capabilities it can provide.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Catalog.Capability

  schema "offices" do
    field :name, :string
    field :intake_capacity, :integer, default: 0

    many_to_many :capabilities, Capability,
      join_through: Scheduling.Offices.OfficeCapability,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(office, attrs) do
    office
    |> cast(attrs, [:name, :intake_capacity])
    |> validate_required([:name, :intake_capacity])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:intake_capacity, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end
end
