defmodule Scheduling.Patients.Patient do
  @moduledoc """
  A minimal patient record. Registration is owned by the external check-in
  app, so we keep only a display name, an optional external identifier
  (check-in app's id), and an optional intake_patient_id (the intake-form
  system's UUID, used to look up compliance forms at accept time).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Queue.QueueEntry

  schema "patients" do
    field :name, :string
    field :external_id, :string
    field :intake_patient_id, Ecto.UUID

    has_many :queue_entries, QueueEntry

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [:name, :external_id, :intake_patient_id])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:external_id)
    |> unique_constraint(:intake_patient_id)
  end
end
