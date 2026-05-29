defmodule Scheduling.Repo.Migrations.CreateOfficeCapabilities do
  use Ecto.Migration

  def change do
    create table(:office_capabilities) do
      add :office_id, references(:offices, on_delete: :delete_all), null: false
      add :capability_id, references(:capabilities, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:office_capabilities, [:office_id])
    create index(:office_capabilities, [:capability_id])
    create unique_index(:office_capabilities, [:office_id, :capability_id])
  end
end
