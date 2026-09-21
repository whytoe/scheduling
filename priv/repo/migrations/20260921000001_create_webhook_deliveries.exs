defmodule Scheduling.Repo.Migrations.CreateWebhookDeliveries do
  use Ecto.Migration

  def change do
    create table(:webhook_deliveries) do
      add :subscription_id,
          references(:webhook_subscriptions, on_delete: :delete_all),
          null: false

      # The visit_events row this delivery came from. A plain reference, not a
      # foreign key: the body is snapshotted below, so a delivery stands on its
      # own and does not need the event to still exist to be re-sent or read.
      add :event_id, :bigint
      add :event_type, :string, null: false

      # The exact JSON we POST, captured at enqueue. Signing happens per attempt
      # with a fresh timestamp, but the body never changes — so a retry sends
      # byte-for-byte what the first attempt did.
      add :body, :text, null: false

      # pending -> delivered | dead. `pending` covers both "never tried" and
      # "waiting to retry"; `next_retry_at` says which.
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_response_status, :integer
      add :last_response_body, :text
      add :last_error, :text
      add :next_retry_at, :utc_datetime
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # The sweeper's query: due work is `status = 'pending' AND next_retry_at <= now`.
    create index(:webhook_deliveries, [:status, :next_retry_at])
    # The operator API filters by subscription.
    create index(:webhook_deliveries, [:subscription_id])

    # Consecutive failed attempts across a subscription, reset to 0 on any
    # success. Auto-disable trips when it crosses the configured threshold, so a
    # permanently-dead endpoint stops being retried against forever.
    alter table(:webhook_subscriptions) do
      add :consecutive_failures, :integer, null: false, default: 0
    end
  end
end
