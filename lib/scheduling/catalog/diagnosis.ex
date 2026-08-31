defmodule Scheduling.Catalog.Diagnosis do
  @moduledoc """
  A diagnosis catalog entry. Each diagnosis maps to a default set of required
  capabilities (via `diagnosis_capabilities`), which a queue entry can inherit
  and then override.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Catalog.Capability

  schema "diagnoses" do
    field :name, :string
    field :code, :string
    field :duration_minutes, :integer, default: 20
    field :required_compliance_refs, {:array, :string}, default: []

    many_to_many :capabilities, Capability,
      join_through: Scheduling.Catalog.DiagnosisCapability,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(diagnosis, attrs) do
    diagnosis
    |> cast(attrs, [:name, :code, :duration_minutes, :required_compliance_refs])
    |> validate_required([:name, :duration_minutes])
    |> validate_length(:name, min: 1, max: 255)
    # A booking has to occupy a whole number of slots, and a zero-length
    # service would occupy none. The upper bound is a full day — anything
    # longer is a data-entry slip, not a service.
    |> validate_number(:duration_minutes,
      greater_than: 0,
      less_than_or_equal_to: 1440
    )
    |> unique_constraint(:name)
    |> unique_constraint(:code)
  end
end
