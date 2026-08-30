defmodule Scheduling.Booking.Appointment do
  @moduledoc """
  A patient booked into a run of consecutive slots on one office.

  ## Binding

  `:committed` when exactly one office could serve the appointment's
  capabilities, `:provisional` when several could. Derived from the capability
  graph at booking time, never chosen — see `docs/booking.md`.

  A committed appointment goes straight to its room on arrival; a provisional
  one goes through the matcher, which may move it and release the slots.

  ## What it stores, and what it does not

  It holds the **resolved capabilities** — "this person needs a CT scanner at
  2pm" — and not the service code that produced them. Scheduling's catalog maps
  codes to human-readable service names, so storing the code would let this
  database answer *why* a named patient is here. That is what
  `docs/data-boundary.md` forbids.

  The code is a transient input to `Scheduling.Booking.book/1`, expanded and
  discarded, exactly as `Scheduling.Queue.create_entry/2` treats it.

  ## Which office

  There is no `office_id` here. The office is whichever one the appointment's
  slots belong to, and slots already carry it — duplicating it would create a
  second answer to the same question, free to drift when BK-4 moves an
  appointment to a different run. `office/1` reads it from the slots.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Booking.Slot
  alias Scheduling.Catalog.Capability
  alias Scheduling.Patients.Patient

  @type t :: %__MODULE__{}

  @statuses [:booked, :arrived, :completed, :cancelled]
  @bindings [:committed, :provisional]

  schema "appointments" do
    field :status, Ecto.Enum, values: @statuses, default: :booked
    field :binding, Ecto.Enum, values: @bindings
    field :external_ref, :string

    belongs_to :patient, Patient
    has_many :slots, Slot

    many_to_many :required_capabilities, Capability,
      join_through: Scheduling.Booking.AppointmentCapability,
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @doc "The valid appointment statuses."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "The valid bindings."
  @spec bindings() :: [atom()]
  def bindings, do: @bindings

  @doc false
  def changeset(appointment, attrs) do
    appointment
    |> cast(attrs, [:patient_id, :status, :binding, :external_ref])
    |> validate_required([:patient_id, :status, :binding])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:binding, @bindings)
    |> validate_length(:external_ref, min: 1, max: 255)
    |> assoc_constraint(:patient)
    |> unique_constraint(:external_ref,
      name: :appointments_external_ref_index,
      message: "has already been booked"
    )
  end

  @doc """
  The office this appointment sits in, read from its slots.

  Returns `nil` when the slots are not loaded or the appointment holds none —
  the latter only after BK-4 releases them.
  """
  @spec office_id(t()) :: integer() | nil
  def office_id(%__MODULE__{slots: slots}) when is_list(slots) do
    case slots do
      [%Slot{office_id: office_id} | _] -> office_id
      [] -> nil
    end
  end

  def office_id(%__MODULE__{}), do: nil

  @doc """
  When the appointment starts — the earliest of its slots.

  Returns `nil` when the slots are not loaded or there are none.
  """
  @spec starts_at(t()) :: DateTime.t() | nil
  def starts_at(%__MODULE__{slots: slots}) when is_list(slots) and slots != [] do
    slots |> Enum.map(& &1.starts_at) |> Enum.min(DateTime)
  end

  def starts_at(%__MODULE__{}), do: nil

  @doc """
  When the appointment ends — the latest end among its slots.

  Read from the slots rather than stored, for the same reason as `office_id/1`.
  """
  @spec ends_at(t()) :: DateTime.t() | nil
  def ends_at(%__MODULE__{slots: slots}) when is_list(slots) and slots != [] do
    slots |> Enum.map(& &1.ends_at) |> Enum.max(DateTime)
  end

  def ends_at(%__MODULE__{}), do: nil
end
