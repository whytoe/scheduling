defmodule Scheduling.Queue.QueueEntry do
  @moduledoc """
  A patient waiting in the queue. Required capabilities follow the BOTH model:
  defaults can be derived from the associated `diagnosis`, and an explicit set
  of `required_capabilities` can be set per entry to override them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Catalog.{Capability, Diagnosis}
  alias Scheduling.Offices.Office
  alias Scheduling.Patients.Patient

  @statuses [:waiting, :assigned, :in_service, :completed]
  @active_statuses [:assigned, :in_service]

  schema "queue_entries" do
    field :status, Ecto.Enum, values: @statuses, default: :waiting
    field :priority, :integer, default: 0

    belongs_to :patient, Patient
    belongs_to :diagnosis, Diagnosis
    belongs_to :assigned_office, Office

    many_to_many :required_capabilities, Capability,
      join_through: Scheduling.Queue.QueueEntryCapability,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc "The valid lifecycle statuses for a queue entry."
  def statuses, do: @statuses

  @doc """
  The statuses that occupy an office's intake capacity. Entries in these
  statuses count toward an office's current load.
  """
  def active_statuses, do: @active_statuses

  @doc false
  def changeset(queue_entry, attrs) do
    queue_entry
    |> cast(attrs, [:patient_id, :diagnosis_id, :assigned_office_id, :status, :priority])
    |> validate_required([:patient_id, :status, :priority])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> assoc_constraint(:patient)
    |> assoc_constraint(:diagnosis)
    |> assoc_constraint(:assigned_office)
  end

  @doc """
  Transitions a waiting entry to `:assigned`, recording the chosen office. Only
  valid from the `:waiting` status; any other current status is rejected so an
  already-assigned patient cannot be silently reassigned.
  """
  def assignment_changeset(%__MODULE__{} = queue_entry, %Office{} = office) do
    queue_entry
    |> change(status: :assigned, assigned_office_id: office.id)
    |> validate_waiting()
    |> assoc_constraint(:assigned_office)
  end

  defp validate_waiting(changeset) do
    case changeset.data.status do
      :waiting -> changeset
      other -> add_error(changeset, :status, "must be waiting to assign, was #{other}")
    end
  end

  @doc """
  Marks service finished: transitions an active entry (`:assigned` or
  `:in_service`) to `:completed`. The assigned office is preserved for the
  audit trail, but because `:completed` is not an active status the office's
  derived load drops immediately, freeing the intake slot.

  Rejected from any non-active status so a waiting or already-completed entry
  cannot be completed.
  """
  def completion_changeset(%__MODULE__{} = queue_entry) do
    queue_entry
    |> change(status: :completed)
    |> validate_active()
  end

  @doc """
  Re-queues an active entry for an additional service: transitions it back to
  `:waiting`, releases its assigned office (freeing the slot), and replaces its
  required capabilities with `capabilities` (the needs of the next service).

  Rejected from any non-active status. Pass the loaded `Capability` structs the
  next service requires; the existing join rows are replaced.
  """
  def requeue_changeset(%__MODULE__{} = queue_entry, capabilities)
      when is_list(capabilities) do
    queue_entry
    |> change(status: :waiting, assigned_office_id: nil)
    |> put_assoc(:required_capabilities, capabilities)
    |> validate_active()
  end

  defp validate_active(changeset) do
    if changeset.data.status in @active_statuses do
      changeset
    else
      add_error(
        changeset,
        :status,
        "must be assigned or in service, was #{changeset.data.status}"
      )
    end
  end

  @doc """
  Replaces the set of required capabilities on the entry. Pass the loaded
  `Capability` structs that should be required; the existing join rows are
  replaced.
  """
  def required_capabilities_changeset(queue_entry, capabilities)
      when is_list(capabilities) do
    queue_entry
    |> change()
    |> put_assoc(:required_capabilities, capabilities)
  end
end
