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

    many_to_many :capabilities, Capability,
      join_through: Scheduling.Catalog.DiagnosisCapability,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(diagnosis, attrs) do
    diagnosis
    |> cast(attrs, [:name, :code])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name)
    |> unique_constraint(:code)
  end
end
