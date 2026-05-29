defmodule Scheduling.Repo.Migrations.AddAssignedOfficeToQueueEntries do
  use Ecto.Migration

  def change do
    alter table(:queue_entries) do
      add :assigned_office_id, references(:offices, on_delete: :nilify_all)
    end

    create index(:queue_entries, [:assigned_office_id])
  end
end
