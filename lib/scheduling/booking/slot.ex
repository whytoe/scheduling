defmodule Scheduling.Booking.Slot do
  @moduledoc """
  One concrete bookable instant on one office.

  Slots are generated from `Scheduling.Booking.AvailabilityRule`s — see
  `Scheduling.Booking.SlotGenerator` — and are stored in **UTC**. The rule they
  came from is expressed in the office's local wall time; the conversion
  happens once, at generation.

  ## Status

    * `:open` — bookable.
    * `:blocked` — deliberately withheld (a room closed for cleaning, a
      one-off absence). Not bookable, but the slot still exists so it is
      visible on a calendar as withheld rather than simply missing.
    * `:booked` — held by an appointment.

  `:blocked` and `:booked` both mean "not available", but they are not
  interchangeable: one is an operational decision and the other is a
  commitment to a patient. Collapsing them would make it impossible to tell a
  closed room from a full one.

  An appointment may span several consecutive slots on the same office when the
  service is longer than the rule's slot length — see `docs/booking.md`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Booking.AvailabilityRule
  alias Scheduling.Offices.Office

  @type t :: %__MODULE__{}

  @statuses [:open, :blocked, :booked]

  schema "slots" do
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :status, Ecto.Enum, values: @statuses, default: :open

    belongs_to :office, Office
    belongs_to :availability_rule, AvailabilityRule

    timestamps(type: :utc_datetime)
  end

  @doc "The valid slot statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "Statuses that make a slot unavailable to book into."
  @spec unavailable_statuses() :: [atom()]
  def unavailable_statuses, do: [:blocked, :booked]

  @doc false
  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [:office_id, :availability_rule_id, :starts_at, :ends_at, :status])
    |> validate_required([:office_id, :starts_at, :ends_at, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_span()
    |> assoc_constraint(:office)
    |> assoc_constraint(:availability_rule)
    |> unique_constraint([:office_id, :starts_at],
      name: :slots_office_id_starts_at_index,
      message: "already has a slot starting at this instant"
    )
  end

  @doc """
  Marks a slot blocked.

  Refuses a booked slot: blocking one would take a room out of service while a
  patient is still expected in it, and the resulting state would say the slot
  was withheld rather than that someone has an appointment. Cancel the
  appointment first — that is a decision with a person on the other end of it,
  and it should be made deliberately rather than as a side effect.
  """
  @spec block_changeset(t()) :: Ecto.Changeset.t()
  def block_changeset(%__MODULE__{status: :booked} = slot) do
    slot
    |> change()
    |> add_error(:status, "cannot block a booked slot; cancel the appointment first")
  end

  def block_changeset(%__MODULE__{} = slot), do: change(slot, status: :blocked)

  @doc """
  Returns a blocked slot to `:open`.

  Refuses a booked slot for the same reason as `block_changeset/1` — silently
  opening it would offer a room that is already committed.
  """
  @spec unblock_changeset(t()) :: Ecto.Changeset.t()
  def unblock_changeset(%__MODULE__{status: :booked} = slot) do
    slot
    |> change()
    |> add_error(:status, "cannot unblock a booked slot; it is held by an appointment")
  end

  def unblock_changeset(%__MODULE__{} = slot), do: change(slot, status: :open)

  defp validate_span(changeset) do
    with %DateTime{} = starts_at <- get_field(changeset, :starts_at),
         %DateTime{} = ends_at <- get_field(changeset, :ends_at) do
      case DateTime.compare(ends_at, starts_at) do
        :gt -> changeset
        _ -> add_error(changeset, :ends_at, "must be after the start")
      end
    else
      _ -> changeset
    end
  end
end
