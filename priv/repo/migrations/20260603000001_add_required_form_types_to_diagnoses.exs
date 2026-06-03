defmodule Scheduling.Repo.Migrations.AddRequiredFormTypesToDiagnoses do
  use Ecto.Migration

  def change do
    alter table(:diagnoses) do
      add :required_form_types, {:array, :string}, null: false, default: []
    end
  end
end
