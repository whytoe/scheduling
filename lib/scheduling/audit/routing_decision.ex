defmodule Scheduling.Audit.RoutingDecision do
  @moduledoc """
  An audit record of one run of the best-fit matcher through the accept flow:
  who was routed, what they needed, which offices were eligible, which office
  was chosen (or none), and the human-readable rationale.

  Office and patient names are snapshotted alongside the foreign keys so the
  record stays meaningful even if the referenced rows are later deleted.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Offices.Office
  alias Scheduling.Patients.Patient
  alias Scheduling.Queue.QueueEntry

  @type t :: %__MODULE__{}

  schema "routing_decisions" do
    field :patient_name, :string
    field :chosen_office_name, :string
    field :required_capabilities, {:array, :string}, default: []
    field :eligible_offices, {:array, :string}, default: []
    field :rationale, :string
    field :accepted_by, :string

    belongs_to :patient, Patient
    belongs_to :queue_entry, QueueEntry
    belongs_to :chosen_office, Office

    timestamps(type: :utc_datetime)
  end

  @castable [
    :patient_id,
    :queue_entry_id,
    :chosen_office_id,
    :patient_name,
    :chosen_office_name,
    :required_capabilities,
    :eligible_offices,
    :rationale,
    :accepted_by
  ]

  @doc false
  def changeset(routing_decision, attrs) do
    routing_decision
    |> cast(attrs, @castable)
    |> validate_required([:rationale])
    |> assoc_constraint(:patient)
    |> assoc_constraint(:queue_entry)
    |> assoc_constraint(:chosen_office)
  end
end
