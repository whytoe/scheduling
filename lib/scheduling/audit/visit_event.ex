defmodule Scheduling.Audit.VisitEvent do
  @moduledoc """
  Long-tail lifecycle event log: sign-in, completion, handoff acknowledgement,
  and (eventually, under sc-7hu) cancel / no_show / disposition transitions.

  Sibling to `Scheduling.Audit.RoutingDecision`, which stays specialized for
  matcher runs (with their FKs to office, eligible_offices array, etc.).
  Visit events are wider in scope and use a jsonb payload for the small
  per-type extras.

  Actor is split into `(actor_type, actor_id)`. Once OAuth (sc-6ea) lands,
  these become the subject claim's type + id; today callers pass them
  through as opts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Handoffs.Handoff
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Visits.Visit

  @type t :: %__MODULE__{}

  schema "visit_events" do
    field :type, :string
    field :actor_type, :string
    field :actor_id, :string
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime

    belongs_to :visit, Visit
    belongs_to :queue_entry, QueueEntry
    belongs_to :patient, Patient
    belongs_to :handoff, Handoff

    timestamps(type: :utc_datetime)
  end

  @castable [
    :type,
    :visit_id,
    :queue_entry_id,
    :patient_id,
    :handoff_id,
    :actor_type,
    :actor_id,
    :payload,
    :occurred_at
  ]

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable)
    |> validate_required([:type, :occurred_at])
    |> validate_length(:type, min: 1, max: 100)
  end
end
