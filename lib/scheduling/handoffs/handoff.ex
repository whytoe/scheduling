defmodule Scheduling.Handoffs.Handoff do
  @moduledoc """
  A durable incoming-patient handoff: when the accept flow assigns a patient to
  an office, one of these records notifies that office's clinical staff that the
  patient is on their way, carrying the patient's required capabilities.

  The record persists with a `:pending`/`:acknowledged` status so an incoming
  patient survives a board reload and only clears once staff acknowledge
  receipt. Patient and office names are snapshotted alongside the foreign keys
  so the handoff stays meaningful even if the referenced rows are later removed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Offices.Office
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  @type t :: %__MODULE__{}

  @statuses [:pending, :acknowledged]

  schema "handoffs" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :patient_name, :string
    field :office_name, :string
    field :required_capabilities, {:array, :string}, default: []
    field :acknowledged_at, :utc_datetime
    field :acknowledged_by, :string

    belongs_to :office, Office
    belongs_to :patient, Patient
    belongs_to :queue_entry, QueueEntry

    timestamps(type: :utc_datetime)
  end

  @doc "The valid handoff statuses."
  def statuses, do: @statuses

  @castable [
    :office_id,
    :patient_id,
    :queue_entry_id,
    :status,
    :patient_name,
    :office_name,
    :required_capabilities,
    :acknowledged_at,
    :acknowledged_by
  ]

  @doc false
  def changeset(handoff, attrs) do
    handoff
    |> cast(attrs, @castable)
    |> validate_required([:office_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:office)
    |> assoc_constraint(:patient)
    |> assoc_constraint(:queue_entry)
  end

  @doc """
  Transitions a `:pending` handoff to `:acknowledged`, stamping when and by whom
  receipt was acknowledged. Only valid from `:pending` so a handoff cannot be
  acknowledged twice. `opts` may carry `:acknowledged_by`.
  """
  def acknowledge_changeset(%__MODULE__{} = handoff, opts \\ []) do
    handoff
    |> change(
      status: :acknowledged,
      acknowledged_at: DateTime.utc_now() |> DateTime.truncate(:second),
      acknowledged_by: Keyword.get(opts, :acknowledged_by)
    )
    |> validate_pending()
  end

  defp validate_pending(changeset) do
    case changeset.data.status do
      :pending -> changeset
      other -> add_error(changeset, :status, "must be pending to acknowledge, was #{other}")
    end
  end
end
