defmodule Scheduling.Repo.Migrations.CreateRoutingDecisions do
  use Ecto.Migration

  def change do
    create table(:routing_decisions) do
      add :patient_id, references(:patients, on_delete: :nilify_all)
      add :queue_entry_id, references(:queue_entries, on_delete: :nilify_all)
      add :chosen_office_id, references(:offices, on_delete: :nilify_all)

      add :patient_name, :string
      add :chosen_office_name, :string
      add :required_capabilities, {:array, :string}, null: false, default: []
      add :eligible_offices, {:array, :string}, null: false, default: []
      add :rationale, :text, null: false
      add :accepted_by, :string

      timestamps(type: :utc_datetime)
    end

    create index(:routing_decisions, [:patient_id])
    create index(:routing_decisions, [:queue_entry_id])
    create index(:routing_decisions, [:chosen_office_id])
  end
end
