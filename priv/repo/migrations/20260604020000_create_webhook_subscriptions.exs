defmodule Scheduling.Repo.Migrations.CreateWebhookSubscriptions do
  use Ecto.Migration

  def change do
    create table(:webhook_subscriptions) do
      add :url, :string, null: false
      add :secret, :string, null: false
      add :event_types, {:array, :string}, null: false, default: []
      add :active, :boolean, null: false, default: true
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create index(:webhook_subscriptions, [:active])
  end
end
