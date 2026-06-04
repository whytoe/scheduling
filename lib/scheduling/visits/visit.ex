defmodule Scheduling.Visits.Visit do
  @moduledoc """
  A visit is one patient encounter, potentially spanning multiple queue
  entries (initial service, follow-up procedure within the same day, etc.).

  The check-in / queueing service creates a Visit when the patient signs
  in; downstream queue entries — including those produced by outbound
  disposition — link back via `queue_entries.visit_id`. Visit lifecycle
  (cancelled / no_show / discharged_with_followup) is tracked under sc-7hu.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  @type t :: %__MODULE__{}

  @statuses [:active, :ended]

  schema "visits" do
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    belongs_to :patient, Patient
    has_many :queue_entries, QueueEntry

    timestamps(type: :utc_datetime)
  end

  @doc "The valid visit statuses."
  def statuses, do: @statuses

  @doc false
  def changeset(visit, attrs) do
    visit
    |> cast(attrs, [:patient_id, :status, :started_at, :ended_at])
    |> default_started_at()
    |> validate_required([:patient_id, :status, :started_at])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:patient)
    |> validate_end_after_start()
  end

  defp default_started_at(changeset) do
    case get_field(changeset, :started_at) do
      nil -> put_change(changeset, :started_at, DateTime.utc_now() |> DateTime.truncate(:second))
      _ -> changeset
    end
  end

  defp validate_end_after_start(changeset) do
    with started when not is_nil(started) <- get_field(changeset, :started_at),
         ended when not is_nil(ended) <- get_field(changeset, :ended_at),
         :gt <- DateTime.compare(started, ended) do
      add_error(changeset, :ended_at, "must be at or after started_at")
    else
      _ -> changeset
    end
  end
end
