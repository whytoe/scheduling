defmodule Scheduling.Patients.Patient do
  @moduledoc """
  A minimal patient record — a **projection** of ac-core's patient registry,
  not an authority. We keep a display name and four correlation ids:

    * `core_patient_id` — the patient's id in ac-core, which is the platform's
      system of record. The identity of record.
    * `client_id` — the canonical scheduling-owned UUID, auto-generated on
      create. **Deprecated** as an inter-service reference in favour of
      `core_patient_id`: it names a row in *this* database, whereas the core id
      names the person every system shares. Still generated and still unique,
      so nothing that already exchanges it breaks.
    * `external_id` — the check-in / queueing service's id for this patient
      (free-form string, unique).
    * `intake_patient_id` — the intake-form system's UUID for this patient
      (used as the correlation key at the compliance gate).

  `name` is a **cache** of what ac-core holds, refreshed by
  `Scheduling.Patients.refresh_from_core/1`, not something this system owns.

  Note what is deliberately absent. ac-core also exposes `mrn`, `dateOfBirth`,
  `phone` and `email`; `Scheduling.Core.Client` drops all four at the boundary
  and there are no columns for them here. They are PII this system could hold
  and has no use for, and a column is an invitation. See
  `docs/data-boundary.md`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Queue.QueueEntry

  schema "patients" do
    field :name, :string
    field :core_patient_id, Ecto.UUID
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
    |> cast(attrs, [:name, :core_patient_id, :client_id, :external_id, :intake_patient_id])
    |> maybe_generate_client_id()
    |> validate_required([:name, :client_id])
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:core_patient_id)
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
