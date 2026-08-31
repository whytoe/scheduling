defmodule Scheduling.Booking.Engine do
  @moduledoc """
  Turning "this patient needs this service, around this time" into a reserved
  appointment.

  Five steps, in order, because each narrows what the next has to consider:

  1. **Resolve the service** to its required capabilities. The service code is
     transient — expanded here and discarded, never stored. See
     `docs/data-boundary.md`.
  2. **Find the eligible offices** — those providing every required capability.
  3. **Derive the binding.** Exactly one eligible office means there is no
     routing decision to make, so the appointment is `:committed` to it.
     Several means `:provisional`, and the matcher may move the patient at
     arrival. None means the booking is refused: nobody can serve it.
  4. **Find a run of consecutive open slots** on one of those offices long
     enough for the service.
  5. **Reserve them**, atomically.

  ## Eligibility is capability-only here

  `Scheduling.Matching.eligible_offices/3` is called with **no loads**. It
  filters on live free capacity, which is right for the walk-in matcher and
  wrong for a booking: for a future appointment the capacity constraint is the
  slot's availability, not today's queue. Passing live loads would refuse to
  book tomorrow a room that happens to be busy right now.

  The default still excludes offices with `intake_capacity` 0, which is
  correct — a room that serves nobody is not bookable.

  ## Reservation is a compare-and-swap

  This is the part that has to be right. Two people booking the same slot at
  the same moment must not both succeed.

  Selecting candidate slots and then updating them leaves a window: both
  callers read the slot as `:open`, both write. Instead the reservation is a
  single conditional update —

      UPDATE slots SET status = 'booked', appointment_id = $1
       WHERE id = ANY($2) AND status = 'open'

  — and the **affected row count must equal the number of slots intended**. If
  it is short, someone else took one between our read and our write; the whole
  transaction rolls back and the caller gets `{:error, :slots_taken}`. The
  `status = 'open'` predicate plus the count is the guarantee. Postgres row
  locks serialise the two updates, so exactly one can see all the rows as open.

  Everything happens inside `Ecto.Multi`, so a refused booking leaves no
  appointment row and no half-reserved slots.

  ## Releasing is the inverse, and fails differently

  `cancel/1` and `reschedule/2` hand slots back. That is not a compare-and-swap:
  nobody contends for slots this appointment already owns, so `WHERE
  appointment_id = $1` is sufficient and matching zero rows is fine — it means
  the release already happened, which makes cancelling idempotent.

  The failure mode is the opposite of double-booking and quieter for it. A
  release that does not happen **strands** capacity: slots stay `:booked`
  against an appointment that no longer wants them, and the room silently
  offers less than it has. Nobody gets an error; the calendar just shrinks. So
  release and the status change are one transaction, and rescheduling searches
  for its new run **after** releasing the old — which also lets an appointment
  move to an overlapping time, since its own slots are open again by then.
  """
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Scheduling.Booking.Appointment
  alias Scheduling.Booking.Slot
  alias Scheduling.Catalog
  alias Scheduling.Matching
  alias Scheduling.Offices
  alias Scheduling.Repo

  @typedoc """
  Why a booking could not be made.

  `:slots_taken` is the concurrent case and is worth retrying; the others are
  not — asking again with the same arguments gives the same answer.
  """
  @type error ::
          :no_service_specified
          | :unknown_service
          | :no_eligible_office
          | :no_available_slots
          | :slots_taken
          | Ecto.Changeset.t()

  @doc """
  Books an appointment.

  Required: `:patient_id`, and one of `:service_code` or
  `:required_capability_ids`. Supplying neither is refused with
  `:no_service_specified` — see `resolve_capabilities/1` for why an omitted
  requirement is not treated as an empty one.

  Optional:

    * `:from` — earliest acceptable start (`DateTime`); defaults to now.
    * `:external_ref` — caller's idempotency key. Booking twice with the same
      ref returns the original appointment rather than a second booking.

  Returns `{:ok, appointment}` with slots, patient and capabilities preloaded.
  """
  @spec book(map()) :: {:ok, Appointment.t()} | {:error, error()}
  def book(attrs) do
    attrs = normalise(attrs)

    with {:ok, existing} <- check_idempotency(attrs[:external_ref]),
         :new <- existing,
         {:ok, capabilities} <- resolve_capabilities(attrs),
         {:ok, offices, binding} <- resolve_binding(capabilities),
         {:ok, run} <- find_run(offices, service_seconds(attrs), attrs[:from]) do
      reserve(run, capabilities, binding, attrs)
    else
      {:already_booked, appointment} -> {:ok, appointment}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Cancels an appointment and hands its slots back.

  Idempotent: cancelling an already-cancelled appointment succeeds and releases
  nothing, because there is nothing left to release.
  """
  @spec cancel(Appointment.t()) :: {:ok, Appointment.t()} | {:error, term()}
  def cancel(%Appointment{} = appointment) do
    Multi.new()
    |> Multi.run(:released, fn repo, _ -> {:ok, release_slots(repo, appointment.id)} end)
    |> Multi.update(:appointment, Appointment.changeset(appointment, %{status: :cancelled}))
    |> Repo.transaction()
    |> case do
      {:ok, %{appointment: cancelled}} -> {:ok, reload(cancelled)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Moves an appointment to a new run of slots.

  Keeps its capabilities — rescheduling changes *when*, not *what*, so the
  service code is never needed again. The binding is **re-derived**, because
  the set of offices able to serve those capabilities may have changed since
  the booking was made.

  Opts: `:from` — earliest acceptable new start; defaults to now.

  The old slots are released first, inside the transaction, so an appointment
  can move to a time that overlaps its current one. If no new run can be found
  the whole thing rolls back and the appointment keeps the slots it had.
  """
  @spec reschedule(Appointment.t(), keyword()) :: {:ok, Appointment.t()} | {:error, error()}
  def reschedule(appointment, opts \\ [])

  def reschedule(%Appointment{status: :cancelled}, _opts), do: {:error, :appointment_cancelled}

  def reschedule(%Appointment{} = appointment, opts) do
    appointment = Repo.preload(appointment, [:required_capabilities, :slots])
    capabilities = appointment.required_capabilities

    # Measured now, before the release: the run it currently holds is the only
    # record of how long this appointment is.
    needed_seconds = booked_seconds(appointment)

    Multi.new()
    |> Multi.run(:released, fn repo, _ -> {:ok, release_slots(repo, appointment.id)} end)
    |> Multi.run(:placement, fn _repo, _ ->
      with {:ok, offices, binding} <- resolve_binding(capabilities),
           {:ok, run} <- find_run(offices, needed_seconds, opts[:from]) do
        {:ok, {run, binding}}
      end
    end)
    |> Multi.run(:claim, fn repo, %{placement: {run, _binding}} ->
      claim_slots(Enum.map(run, & &1.id), appointment.id, repo)
    end)
    |> Multi.run(:appointment, fn repo, %{placement: {_run, binding}} ->
      appointment
      |> Appointment.changeset(%{binding: binding})
      |> repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{appointment: moved}} -> {:ok, reload(moved)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # Not a compare-and-swap: nobody else holds these. Zero rows means the
  # release already happened, which is what makes cancel/1 idempotent.
  defp release_slots(repo, appointment_id) do
    {released, _} =
      Slot
      |> where([s], s.appointment_id == ^appointment_id)
      |> repo.update_all(set: [status: :open, appointment_id: nil])

    released
  end

  @doc """
  Candidate start times for a service in a window — what a booking screen needs
  to offer someone a choice.

  `book/1` deliberately takes the *earliest* qualifying run, which is right for
  a machine caller and useless for a human choosing between 10:00 and 14:00.
  This returns every start where a run would fit, per office.

  Same rules as booking: contiguity, service duration, eligible offices only.
  It is a **preview**, not a hold — anything listed can be taken before the
  operator clicks, and `book/1` is still the thing that decides.

  Opts: `:from`, `:to`, `:limit` (default 50).
  """
  @spec available_starts(map(), keyword()) ::
          {:ok, [%{office_id: integer(), starts_at: DateTime.t()}]} | {:error, error()}
  def available_starts(attrs, opts \\ []) do
    attrs = normalise(attrs)

    with {:ok, capabilities} <- resolve_capabilities(attrs),
         {:ok, offices, _binding} <- resolve_binding(capabilities) do
      from = opts[:from] || DateTime.utc_now()
      needed_seconds = service_seconds(attrs)

      starts =
        offices
        |> Enum.map(& &1.id)
        |> open_slots_between(from, opts[:to])
        |> Enum.group_by(& &1.office_id)
        |> Enum.flat_map(fn {office_id, slots} ->
          slots
          |> Enum.sort_by(& &1.starts_at, DateTime)
          |> runs_from_each_start()
          |> Enum.filter(&take_contiguous(&1, needed_seconds))
          |> Enum.map(&%{office_id: office_id, starts_at: hd(&1).starts_at})
        end)
        |> Enum.sort_by(& &1.starts_at, DateTime)
        |> Enum.take(opts[:limit] || 50)

      {:ok, starts}
    end
  end

  defp open_slots_between(office_ids, from, nil), do: open_slots_from(office_ids, from)

  defp open_slots_between(office_ids, from, to) do
    Slot
    |> where(
      [s],
      s.office_id in ^office_ids and s.status == :open and
        s.starts_at >= ^from and s.starts_at < ^to
    )
    |> order_by([s], asc: s.office_id, asc: s.starts_at)
    |> Repo.all()
  end

  # --- 1. the service ---------------------------------------------------------

  defp resolve_capabilities(%{required_capability_ids: ids}) when is_list(ids) do
    {:ok, Catalog.list_capabilities_by_ids(ids)}
  end

  defp resolve_capabilities(%{service_code: code}) when is_binary(code) and code != "" do
    case Catalog.fetch_diagnosis_by_code(code) do
      {:ok, service} -> {:ok, service.capabilities}
      :error -> {:error, :unknown_service}
    end
  end

  # Neither a service code nor a capability list. Almost always a caller that
  # forgot one — and booking a room for an unspecified purpose is worse than
  # refusing, because an empty requirement matches *every* office and quietly
  # reserves the first free slot anywhere.
  #
  # An explicit empty `required_capability_ids: []` is honoured above and means
  # "any room will do", which is a real intent. Omitting the key entirely is
  # not the same statement.
  defp resolve_capabilities(_attrs), do: {:error, :no_service_specified}

  # --- 2 & 3. offices and binding ---------------------------------------------

  # No loads: see the moduledoc. A future booking's capacity is the slot.
  defp resolve_binding(capabilities) do
    case Matching.eligible_offices(capabilities, Offices.list_offices()) do
      [] -> {:error, :no_eligible_office}
      [_only] = offices -> {:ok, offices, :committed}
      offices -> {:ok, offices, :provisional}
    end
  end

  # --- 4. the slot run --------------------------------------------------------

  # Slot length varies per rule, so "how many slots" is not a division — walk
  # the actual boundaries until the run is long enough.
  defp find_run(offices, needed_seconds, from) do
    from = from || DateTime.utc_now()

    offices
    |> Enum.map(& &1.id)
    |> open_slots_from(from)
    |> Enum.group_by(& &1.office_id)
    |> Enum.map(fn {_office_id, slots} -> first_run(slots, needed_seconds) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&hd(&1).starts_at, DateTime, fn -> nil end)
    |> case do
      nil -> {:error, :no_available_slots}
      run -> {:ok, run}
    end
  end

  defp open_slots_from(office_ids, from) do
    Slot
    |> where([s], s.office_id in ^office_ids and s.status == :open and s.starts_at >= ^from)
    |> order_by([s], asc: s.office_id, asc: s.starts_at)
    |> Repo.all()
  end

  # The earliest contiguous run covering `needed_seconds`. Contiguous means
  # each slot begins exactly where the previous ended — a gap (a lunch break
  # between two rules) breaks the run rather than being booked through.
  defp first_run(slots, needed_seconds) do
    slots
    |> Enum.sort_by(& &1.starts_at, DateTime)
    |> runs_from_each_start()
    |> Enum.find_value(fn candidates -> take_contiguous(candidates, needed_seconds) end)
  end

  defp runs_from_each_start([]), do: []
  defp runs_from_each_start([_ | rest] = slots), do: [slots | runs_from_each_start(rest)]

  defp take_contiguous([first | _] = slots, needed_seconds) do
    Enum.reduce_while(slots, {[], first.starts_at}, fn slot, {acc, expected_start} ->
      cond do
        DateTime.compare(slot.starts_at, expected_start) != :eq ->
          {:halt, {:gap, acc}}

        long_enough?(first, slot, needed_seconds) ->
          {:halt, {:done, Enum.reverse([slot | acc])}}

        true ->
          {:cont, {[slot | acc], slot.ends_at}}
      end
    end)
    |> case do
      {:done, run} -> run
      _ -> nil
    end
  end

  defp long_enough?(first, last, needed_seconds) do
    DateTime.diff(last.ends_at, first.starts_at, :second) >= needed_seconds
  end

  defp service_seconds(%{service_code: code}) when is_binary(code) do
    case Catalog.fetch_diagnosis_by_code(code) do
      {:ok, %{duration_minutes: minutes}} when is_integer(minutes) -> minutes * 60
      _ -> 0
    end
  end

  # With an explicit capability list there is no service to take a duration
  # from, so one slot is the unit. Zero seconds is satisfied by the first slot.
  defp service_seconds(_attrs), do: 0

  @doc """
  How long an appointment currently runs for, in seconds.

  This is how a reschedule knows its own length. The appointment does not store
  the service code — deliberately, see `Scheduling.Booking.Appointment` — so
  the duration cannot be looked up again. Its existing run *is* the duration,
  and it has to be measured before the old slots are released.
  """
  @spec booked_seconds(Appointment.t()) :: non_neg_integer()
  def booked_seconds(%Appointment{slots: slots}) when is_list(slots) and slots != [] do
    starts_at = slots |> Enum.map(& &1.starts_at) |> Enum.min(DateTime)
    ends_at = slots |> Enum.map(& &1.ends_at) |> Enum.max(DateTime)
    DateTime.diff(ends_at, starts_at, :second)
  end

  def booked_seconds(%Appointment{}), do: 0

  # --- 5. reservation ---------------------------------------------------------

  defp reserve(run, capabilities, binding, attrs) do
    slot_ids = Enum.map(run, & &1.id)

    Multi.new()
    |> Multi.insert(:appointment, appointment_changeset(capabilities, binding, attrs))
    |> Multi.run(:slots, fn repo, %{appointment: appointment} ->
      claim_slots(slot_ids, appointment.id, repo)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{appointment: appointment}} -> {:ok, reload(appointment)}
      {:error, :slots, reason, _changes} -> {:error, reason}
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  The reservation compare-and-swap: claim every one of `slot_ids` for
  `appointment_id`, or none.

  Returns `{:ok, count}` when all were open and are now booked, and
  `{:error, :slots_taken}` when at least one was not — meaning a concurrent
  booking got there first.

  **Must be called inside a transaction.** On the short-count path it reports
  failure but does not itself undo the rows it did claim; the surrounding
  `Ecto.Multi` rolling back is what releases them. `book/1` provides that.

  Public because it is the crux of the whole engine and the branch a genuine
  race takes. Under `Ecto.Adapters.SQL.Sandbox` every process shares one
  connection, so tests cannot produce a real parallel race — they drive this
  function directly instead, which exercises the same code path a race would.
  """
  @spec claim_slots([integer()], integer(), Ecto.Repo.t()) ::
          {:ok, non_neg_integer()} | {:error, :slots_taken}
  def claim_slots(slot_ids, appointment_id, repo \\ Repo) do
    expected = length(slot_ids)

    {claimed, _} =
      Slot
      |> where([s], s.id in ^slot_ids and s.status == :open)
      |> repo.update_all(set: [status: :booked, appointment_id: appointment_id])

    if claimed == expected do
      {:ok, claimed}
    else
      # Someone took one between our read and our write. Rolling back the
      # transaction releases whatever this call did claim.
      {:error, :slots_taken}
    end
  end

  defp appointment_changeset(capabilities, binding, attrs) do
    %Appointment{required_capabilities: []}
    |> Appointment.changeset(%{
      patient_id: attrs[:patient_id],
      binding: binding,
      status: :booked,
      external_ref: attrs[:external_ref]
    })
    |> Ecto.Changeset.put_assoc(:required_capabilities, capabilities)
  end

  # --- idempotency ------------------------------------------------------------

  defp check_idempotency(nil), do: {:ok, :new}
  defp check_idempotency(""), do: {:ok, :new}

  defp check_idempotency(ref) do
    case Repo.get_by(Appointment, external_ref: ref) do
      nil -> {:ok, :new}
      appointment -> {:already_booked, reload(appointment)}
    end
  end

  defp reload(appointment) do
    Repo.preload(appointment, [:patient, :required_capabilities, :slots], force: true)
  end

  defp normalise(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end
end
