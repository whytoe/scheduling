defmodule Scheduling.Repo.Migrations.CreateQueueEntries do
  use Ecto.Migration

  def change do
    create table(:queue_entries) do
      add :patient_id, references(:patients, on_delete: :delete_all), null: false
      add :diagnosis_id, references(:diagnoses, on_delete: :nilify_all)
      add :status, :string, null: false, default: "waiting"
      add :priority, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:queue_entries, [:patient_id])
    create index(:queue_entries, [:diagnosis_id])
    create index(:queue_entries, [:status])
  end
end
