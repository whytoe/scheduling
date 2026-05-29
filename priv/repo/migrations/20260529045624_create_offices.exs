defmodule Scheduling.Repo.Migrations.CreateOffices do
  use Ecto.Migration

  def change do
    create table(:offices) do
      add :name, :string, null: false
      add :intake_capacity, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:offices, [:name])
  end
end
