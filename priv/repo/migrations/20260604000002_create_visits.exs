defmodule Scheduling.Repo.Migrations.CreateVisits do
  use Ecto.Migration

  def change do
    create table(:visits) do
      add :patient_id, references(:patients, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "active"
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:visits, [:patient_id])
    create index(:visits, [:status])

    alter table(:queue_entries) do
      add :visit_id, references(:visits, on_delete: :nilify_all)
    end

    create index(:queue_entries, [:visit_id])
  end
end
