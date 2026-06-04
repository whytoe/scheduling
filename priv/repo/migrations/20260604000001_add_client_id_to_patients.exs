defmodule Scheduling.Repo.Migrations.AddClientIdToPatients do
  use Ecto.Migration

  def change do
    alter table(:patients) do
      add :client_id, :uuid
    end

    # Backfill existing rows with random uuids so we can mark the column NOT NULL.
    execute(
      "UPDATE patients SET client_id = gen_random_uuid() WHERE client_id IS NULL",
      ""
    )

    alter table(:patients) do
      modify :client_id, :uuid, null: false
    end

    create unique_index(:patients, [:client_id])
  end
end
