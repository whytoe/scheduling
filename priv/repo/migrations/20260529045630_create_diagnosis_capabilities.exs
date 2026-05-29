defmodule Scheduling.Repo.Migrations.CreateDiagnosisCapabilities do
  use Ecto.Migration

  def change do
    create table(:diagnosis_capabilities) do
      add :diagnosis_id, references(:diagnoses, on_delete: :delete_all), null: false
      add :capability_id, references(:capabilities, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:diagnosis_capabilities, [:diagnosis_id])
    create index(:diagnosis_capabilities, [:capability_id])
    create unique_index(:diagnosis_capabilities, [:diagnosis_id, :capability_id])
  end
end
