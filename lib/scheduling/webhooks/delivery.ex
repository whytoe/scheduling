defmodule Scheduling.Webhooks.Delivery do
  @moduledoc """
  One durable attempt-with-retries to deliver an event to a subscription.

  `Scheduling.Webhooks.dispatch/1` used to fan out fire-and-forget: a slow or
  down receiver simply dropped the event, with no record it ever happened. A
  delivery row makes each fan-out durable — it is enqueued in the same
  transaction as the event, retried on a backoff by `Scheduling.Webhooks.Sweeper`,
  and moved to the dead-letter state after the configured number of attempts.

  The `body` is the exact JSON posted, snapshotted at enqueue. Only the
  signature (and its timestamp) changes between attempts, so a retry is
  byte-identical to the first try and does not depend on the source event still
  existing.

  ## States

    * `:pending` — not yet delivered. `next_retry_at` says when the next attempt
      is due; a brand-new row has it set to now.
    * `:delivered` — a `2xx` was received. Terminal.
    * `:dead` — every attempt failed. Terminal; the dead-letter queue is just
      `where status == :dead`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Webhooks.Subscription

  @type t :: %__MODULE__{}

  @statuses [:pending, :delivered, :dead]

  schema "webhook_deliveries" do
    field :event_id, :integer
    field :event_type, :string
    field :body, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :attempts, :integer, default: 0
    field :last_response_status, :integer
    field :last_response_body, :string
    field :last_error, :string
    field :next_retry_at, :utc_datetime
    field :delivered_at, :utc_datetime

    belongs_to :subscription, Subscription

    timestamps(type: :utc_datetime)
  end

  @doc "The valid delivery statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :subscription_id,
      :event_id,
      :event_type,
      :body,
      :status,
      :attempts,
      :last_response_status,
      :last_response_body,
      :last_error,
      :next_retry_at,
      :delivered_at
    ])
    |> validate_required([:subscription_id, :event_type, :body, :status, :attempts])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:subscription)
  end
end
