defmodule Scheduling.Patients.Patient do
  @moduledoc """
  A minimal patient record. Registration is owned by the external check-in /
  queueing service, so we keep only a display name and three correlation ids:

    * `client_id` — the canonical, scheduling-owned UUID. Auto-generated on
      create if not supplied. **Not** the EMR record id; used as the stable
      reference exchanged across services.
    * `external_id` — the check-in / queueing service's id for this patient
      (free-form string, unique).
    * `intake_patient_id` — the intake-form system's UUID for this patient
      (used as the correlation key at the compliance gate).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Queue.QueueEntry

  schema "patients" do
    field :name, :string
    field :client_id, Ecto.UUID
    field :external_id, :string
    field :intake_patient_id, Ecto.UUID

    has_many :queue_entries, QueueEntry

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for create / update. Auto-generates `client_id` on insert when
  the caller doesn't supply one, so external systems don't have to.
  """
  def changeset(patient, attrs) do
    patient
    |> cast(attrs, [:name, :client_id, :external_id, :intake_patient_id])
    |> maybe_generate_client_id()
    |> validate_required([:name, :client_id])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:client_id)
    |> unique_constraint(:external_id)
    |> unique_constraint(:intake_patient_id)
  end

  defp maybe_generate_client_id(changeset) do
    case get_field(changeset, :client_id) do
      nil -> put_change(changeset, :client_id, Ecto.UUID.generate())
      _ -> changeset
    end
  end
end
