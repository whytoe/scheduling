defmodule Scheduling.Queue.QueueEntry do
  @moduledoc """
  A patient waiting in the queue.

  Carries only what routing needs: who (`patient_id`), what equipment
  (`required_capabilities`), and where they ended up (`assigned_office_id`).
  It deliberately does **not** record why the patient is here — that is health
  data and lives in the EMR. See `docs/data-boundary.md`.

  `required_capabilities` is the single source of routing truth;
  `Scheduling.Matching.match_queue_entry/2` reads nothing else. A diagnosis may
  be supplied at creation as a convenience (`Scheduling.Queue.create_entry/2`
  expands it to its default capabilities), but it is expanded and discarded —
  never stored against the patient.

  `compliance_ref` is an opaque token from whoever created the entry. The
  intake-form system resolves it to the forms this encounter requires;
  scheduling passes it through and never learns the form types.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Catalog.Capability
  alias Scheduling.Offices.Office
  alias Scheduling.Patients.Patient
  alias Scheduling.Visits.Visit

  @statuses [:waiting, :assigned, :in_service, :completed]
  @active_statuses [:assigned, :in_service]

  schema "queue_entries" do
    field :status, Ecto.Enum, values: @statuses, default: :waiting
    field :priority, :integer, default: 0
    field :compliance_ref, :string

    belongs_to :patient, Patient
    belongs_to :assigned_office, Office
    belongs_to :visit, Visit

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
    |> cast(attrs, [
      :patient_id,
      :assigned_office_id,
      :visit_id,
      :status,
      :priority,
      :compliance_ref
    ])
    |> validate_required([:patient_id, :status, :priority])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_length(:compliance_ref, max: 255)
    |> assoc_constraint(:patient)
    |> assoc_constraint(:assigned_office)
    |> assoc_constraint(:visit)
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
  Transitions an in-progress entry to `:completed`. Valid only from a status
  that occupies capacity (`assigned`/`in_service`); completing frees the
  office's slot because `:completed` is not an active status. The
  `assigned_office_id` is retained as a record of where the patient was served.
  """
  def completion_changeset(%__MODULE__{} = queue_entry) do
    queue_entry
    |> change(status: :completed)
    |> validate_active("complete")
  end

  @doc """
  Returns an in-progress entry to the `:waiting` queue so the patient can be
  routed again for an additional service. Clears the office assignment (freeing
  its capacity) and, when `:required_capabilities` is given in `opts`, replaces
  the required-capability set with the new requirements. Valid only from an
  active status (`assigned`/`in_service`).

  Pass loaded `Capability` structs in `opts[:required_capabilities]`; the entry
  must have `:required_capabilities` preloaded for the replacement to apply.
  """
  def requeue_changeset(%__MODULE__{} = queue_entry, opts \\ []) do
    queue_entry
    |> change(status: :waiting, assigned_office_id: nil)
    |> validate_active("re-queue")
    |> maybe_put_required_capabilities(opts)
  end

  defp validate_active(changeset, action) do
    if changeset.data.status in @active_statuses do
      changeset
    else
      add_error(
        changeset,
        :status,
        "must be assigned or in_service to #{action}, was #{changeset.data.status}"
      )
    end
  end

  defp maybe_put_required_capabilities(changeset, opts) do
    case Keyword.fetch(opts, :required_capabilities) do
      {:ok, caps} when is_list(caps) -> put_assoc(changeset, :required_capabilities, caps)
      _ -> changeset
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
