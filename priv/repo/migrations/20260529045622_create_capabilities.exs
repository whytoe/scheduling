defmodule Scheduling.Repo.Migrations.CreateCapabilities do
  use Ecto.Migration

  def change do
    create table(:capabilities) do
      add :name, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:capabilities, [:name])
  end
end
