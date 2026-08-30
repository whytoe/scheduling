defmodule Scheduling.Repo.Migrations.AddCorePatientIdToPatients do
  @moduledoc """
  ac-core is the source of truth for patient identity; a row here is a
  projection of that registry, not an authority of its own.

  Nullable because existing rows have no reliable key to backfill from — there
  is no local field that maps to a core id — so they stay null and populate on
  next touch. Uniquely indexed because two local rows projecting the same core
  patient would be a split identity, which is the specific failure this column
  exists to prevent.
  """
  use Ecto.Migration

  def change do
    alter table(:patients) do
      add :core_patient_id, :uuid, null: true
    end

    create unique_index(:patients, [:core_patient_id])
  end
end
