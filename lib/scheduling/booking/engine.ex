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
          :unknown_service
          | :no_eligible_office
          | :no_available_slots
          | :slots_taken
          | Ecto.Changeset.t()

  @doc """
  Books an appointment.

  Required: `:patient_id`, and one of `:service_code` or
  `:required_capability_ids`.

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
         {:ok, run} <- find_run(offices, capabilities, attrs) do
      reserve(run, capabilities, binding, attrs)
    else
      {:already_booked, appointment} -> {:ok, appointment}
      {:error, reason} -> {:error, reason}
    end
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

  defp resolve_capabilities(_attrs), do: {:ok, []}

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
  defp find_run(offices, capabilities, attrs) do
    from = attrs[:from] || DateTime.utc_now()
    needed_seconds = service_seconds(capabilities, attrs)

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

  defp service_seconds(_capabilities, %{service_code: code}) when is_binary(code) do
    case Catalog.fetch_diagnosis_by_code(code) do
      {:ok, %{duration_minutes: minutes}} when is_integer(minutes) -> minutes * 60
      _ -> 0
    end
  end

  # With an explicit capability list there is no service to take a duration
  # from, so one slot is the unit. Zero seconds is satisfied by the first slot.
  defp service_seconds(_capabilities, _attrs), do: 0

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
