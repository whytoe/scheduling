defmodule Scheduling.Booking.AppointmentCapability do
  @moduledoc """
  Join between an appointment and the capabilities it requires.

  Mirrors `Scheduling.Queue.QueueEntryCapability`. The appointment holds the
  **resolved equipment requirement**, never the service code that produced it —
  see `Scheduling.Booking.Appointment` and `docs/data-boundary.md`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Booking.Appointment
  alias Scheduling.Catalog.Capability

  schema "appointment_capabilities" do
    belongs_to :appointment, Appointment
    belongs_to :capability, Capability

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(join, attrs) do
    join
    |> cast(attrs, [:appointment_id, :capability_id])
    |> validate_required([:appointment_id, :capability_id])
    |> unique_constraint([:appointment_id, :capability_id])
  end
end
