defmodule Scheduling.Repo.Migrations.AddIntakePatientIdToPatients do
  use Ecto.Migration

  def change do
    alter table(:patients) do
      add :intake_patient_id, :uuid, null: true
    end

    create unique_index(:patients, [:intake_patient_id])
  end
end
