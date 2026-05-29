defmodule Scheduling.Repo.Migrations.CreatePatients do
  use Ecto.Migration

  def change do
    create table(:patients) do
      add :name, :string, null: false
      add :external_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:patients, [:external_id])
  end
end
