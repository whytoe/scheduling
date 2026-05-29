defmodule Scheduling.Repo.Migrations.CreateQueueEntryCapabilities do
  use Ecto.Migration

  def change do
    create table(:queue_entry_capabilities) do
      add :queue_entry_id, references(:queue_entries, on_delete: :delete_all), null: false
      add :capability_id, references(:capabilities, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:queue_entry_capabilities, [:queue_entry_id])
    create index(:queue_entry_capabilities, [:capability_id])
    create unique_index(:queue_entry_capabilities, [:queue_entry_id, :capability_id])
  end
end
