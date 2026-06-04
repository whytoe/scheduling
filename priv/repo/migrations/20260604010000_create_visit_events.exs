defmodule Scheduling.Repo.Migrations.CreateVisitEvents do
  use Ecto.Migration

  def change do
    create table(:visit_events) do
      add :type, :string, null: false
      add :visit_id, references(:visits, on_delete: :nilify_all)
      add :queue_entry_id, references(:queue_entries, on_delete: :nilify_all)
      add :patient_id, references(:patients, on_delete: :nilify_all)
      add :handoff_id, references(:handoffs, on_delete: :nilify_all)
      add :actor_type, :string
      add :actor_id, :string
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:visit_events, [:visit_id, :occurred_at])
    create index(:visit_events, [:queue_entry_id, :occurred_at])
    create index(:visit_events, [:patient_id, :occurred_at])
    create index(:visit_events, [:handoff_id])
    create index(:visit_events, [:type])
    create index(:visit_events, [:occurred_at])
  end
end
