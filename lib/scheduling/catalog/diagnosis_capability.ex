defmodule Scheduling.Catalog.DiagnosisCapability do
  @moduledoc """
  Join table mapping a `Diagnosis` to the `Capability` entries it requires by
  default.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Catalog.{Capability, Diagnosis}

  schema "diagnosis_capabilities" do
    belongs_to :diagnosis, Diagnosis
    belongs_to :capability, Capability

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(diagnosis_capability, attrs) do
    diagnosis_capability
    |> cast(attrs, [:diagnosis_id, :capability_id])
    |> validate_required([:diagnosis_id, :capability_id])
    |> assoc_constraint(:diagnosis)
    |> assoc_constraint(:capability)
    |> unique_constraint([:diagnosis_id, :capability_id])
  end
end
