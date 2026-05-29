defmodule Scheduling.Repo.Migrations.CreateDiagnoses do
  use Ecto.Migration

  def change do
    create table(:diagnoses) do
      add :name, :string, null: false
      add :code, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:diagnoses, [:name])
    create unique_index(:diagnoses, [:code])
  end
end
