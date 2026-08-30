defmodule Scheduling.Booking.Arrival do
  @moduledoc """
  Where a booking meets the queue.

  A booked patient turning up produces the same things a walk-in does — a
  `Visit` and a `QueueEntry` — so the entire existing lifecycle (matching,
  handoffs, completion, the board, the audit log) takes over unchanged. Booking
  decides *when* and *what equipment*; the queue still decides everything after
  the patient is through the door.

  The queue entry carries the appointment's **capabilities**, not a fresh
  lookup from a service code. The appointment does not store a code, and
  re-deriving one would be the leak `docs/data-boundary.md` exists to prevent.

  ## Committed and provisional diverge here, and only here

  This is the one place the binding actually does anything.

  * **`:committed`** — exactly one office could ever serve this appointment,
    and it holds slots there. There is no routing decision to make, so the
    entry is assigned to that office directly and a handoff is raised, exactly
    as `Scheduling.Queue.accept/2` would have done. Running the matcher would
    ask a question with one possible answer.

  * **`:provisional`** — several offices could serve it. The entry is left
    `:waiting` and goes through `Scheduling.Queue.accept/2` like any other,
    so the matcher picks using live capacity at the moment of arrival rather
    than whatever was true when the booking was made. It may well choose a
    different room from the one holding the slots; that is the point.

  ## The slots are not released on arrival

  A committed appointment's slots stay `:booked`. They represent the room's
  time being spent, and the patient is now spending it. Releasing them would
  let a second patient be booked into a room already occupied.

  Provisional slots stay booked too, even when the matcher sends the patient
  elsewhere. Releasing them mid-session would hand out capacity that the
  original room has notionally set aside, and reconciling that is a scheduling
  policy question rather than something to decide implicitly here. Noted in
  `docs/booking.md` as open.

  ## Arriving twice

  `arrive/2` is idempotent on an already-arrived appointment: it returns the
  existing visit and entry rather than opening a second one. A patient checked
  in twice at the desk is a routine mistake, not something to punish with a
  duplicate queue entry.
  """
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Scheduling.Booking.Appointment
  alias Scheduling.Handoffs
  alias Scheduling.Offices
  alias Scheduling.Queue
  alias Scheduling.Queue.QueueEntry
  alias Scheduling.Repo
  alias Scheduling.Visits

  @typedoc """
  What arrival produced. `entry` is `:assigned` for a committed appointment and
  `:waiting` for a provisional one.
  """
  @type result :: %{
          appointment: Appointment.t(),
          visit: Visits.Visit.t(),
          entry: QueueEntry.t()
        }

  @type error :: :appointment_cancelled | :no_slots | Ecto.Changeset.t()

  @doc """
  Records a booked patient arriving: opens a visit, puts them in the queue, and
  for a committed appointment assigns the room and raises the handoff.

  `opts` may carry `:actor_type` / `:actor_id`, which flow into the audit log
  exactly as they do for a walk-in.
  """
  @spec arrive(Appointment.t(), keyword()) :: {:ok, result()} | {:error, error()}
  def arrive(appointment, opts \\ [])

  def arrive(%Appointment{status: :cancelled}, _opts), do: {:error, :appointment_cancelled}

  def arrive(%Appointment{status: :arrived} = appointment, _opts) do
    {:ok, existing_result(appointment)}
  end

  def arrive(%Appointment{} = appointment, opts) do
    appointment = Repo.preload(appointment, [:required_capabilities, :slots])

    case office_for(appointment) do
      nil ->
        {:error, :no_slots}

      office ->
        appointment
        |> arrival_multi(office, opts)
        |> Repo.transaction()
        |> case do
          {:ok, changes} -> {:ok, finish(changes)}
          {:error, _step, reason, _changes} -> {:error, reason}
        end
    end
  end

  defp arrival_multi(appointment, office, opts) do
    Multi.new()
    |> Multi.run(:visit, fn _repo, _ ->
      Visits.create_visit(%{patient_id: appointment.patient_id}, opts)
    end)
    |> Multi.run(:entry, fn _repo, %{visit: visit} ->
      Queue.create_entry(
        %{
          "patient_id" => appointment.patient_id,
          "visit_id" => visit.id,
          "appointment_id" => appointment.id,
          "required_capability_ids" => Enum.map(appointment.required_capabilities, & &1.id)
        },
        opts
      )
    end)
    |> Multi.run(:placed, fn _repo, %{entry: entry} ->
      place(appointment, entry, office)
    end)
    |> Multi.update(:appointment, Appointment.changeset(appointment, %{status: :arrived}))
  end

  # Committed: assign directly. There is one eligible office and the
  # appointment already holds its time, so the matcher has nothing to decide.
  defp place(%Appointment{binding: :committed}, entry, office) do
    with {:ok, assigned} <- entry |> QueueEntry.assignment_changeset(office) |> Repo.update(),
         {:ok, _handoff} <- Handoffs.create_handoff(assigned, office) do
      {:ok, assigned}
    end
  end

  # Provisional: leave it waiting. Scheduling.Queue.accept/2 will run the
  # matcher against live capacity, which is the whole reason not to pin it.
  defp place(%Appointment{binding: :provisional}, entry, _office), do: {:ok, entry}

  # Which office the appointment's slots sit in. Nil only if it holds none,
  # which BK-4's release leaves behind on a cancelled appointment.
  defp office_for(%Appointment{} = appointment) do
    case Appointment.office_id(appointment) do
      nil -> nil
      office_id -> Offices.get_office!(office_id)
    end
  end

  # The Multi's :appointment step holds the *updated* struct. Preloading the
  # one passed in would hand back a status of :booked after we just set
  # :arrived — stale, and quietly wrong for any caller that trusts it.
  defp finish(%{visit: visit, placed: entry, appointment: updated}) do
    %{
      appointment: Repo.preload(updated, [:slots, :required_capabilities], force: true),
      visit: visit,
      entry: Queue.get_entry!(entry.id)
    }
  end

  # An already-arrived appointment: hand back what it produced the first time
  # rather than opening a second visit.
  defp existing_result(appointment) do
    entry =
      QueueEntry
      |> where([e], e.appointment_id == ^appointment.id)
      |> order_by([e], asc: e.id)
      |> limit(1)
      |> Repo.one()

    %{
      appointment: appointment,
      visit: entry && Repo.preload(entry, :visit).visit,
      entry: entry && Queue.get_entry!(entry.id)
    }
  end
end
