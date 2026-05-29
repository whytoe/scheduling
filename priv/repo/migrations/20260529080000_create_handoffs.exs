defmodule Scheduling.Repo.Migrations.CreateHandoffs do
  use Ecto.Migration

  def change do
    create table(:handoffs) do
      add :office_id, references(:offices, on_delete: :nilify_all)
      add :patient_id, references(:patients, on_delete: :nilify_all)
      add :queue_entry_id, references(:queue_entries, on_delete: :nilify_all)

      add :status, :string, null: false, default: "pending"
      add :patient_name, :string
      add :office_name, :string
      add :required_capabilities, {:array, :string}, null: false, default: []
      add :acknowledged_at, :utc_datetime
      add :acknowledged_by, :string

      timestamps(type: :utc_datetime)
    end

    create index(:handoffs, [:office_id])
    create index(:handoffs, [:patient_id])
    create index(:handoffs, [:queue_entry_id])
    create index(:handoffs, [:office_id, :status])
  end
end
