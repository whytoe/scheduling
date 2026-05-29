defmodule Scheduling.Patients.Patient do
  @moduledoc """
  A minimal patient record. Registration is owned by the external check-in
  app, so we keep only a display name and an optional external identifier.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Queue.QueueEntry

  schema "patients" do
    field :name, :string
    field :external_id, :string

    has_many :queue_entries, QueueEntry

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [:name, :external_id])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:external_id)
  end
end
