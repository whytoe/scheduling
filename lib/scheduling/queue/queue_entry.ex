defmodule Scheduling.Queue.QueueEntry do
  @moduledoc """
  A patient waiting in the queue. Required capabilities follow the BOTH model:
  defaults can be derived from the associated `diagnosis`, and an explicit set
  of `required_capabilities` can be set per entry to override them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Catalog.{Capability, Diagnosis}
  alias Scheduling.Patients.Patient

  @statuses [:waiting, :assigned, :in_service, :completed]

  schema "queue_entries" do
    field :status, Ecto.Enum, values: @statuses, default: :waiting
    field :priority, :integer, default: 0

    belongs_to :patient, Patient
    belongs_to :diagnosis, Diagnosis

    many_to_many :required_capabilities, Capability,
      join_through: Scheduling.Queue.QueueEntryCapability,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc "The valid lifecycle statuses for a queue entry."
  def statuses, do: @statuses

  @doc false
  def changeset(queue_entry, attrs) do
    queue_entry
    |> cast(attrs, [:patient_id, :diagnosis_id, :status, :priority])
    |> validate_required([:patient_id, :status, :priority])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> assoc_constraint(:patient)
    |> assoc_constraint(:diagnosis)
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
