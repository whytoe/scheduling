defmodule Scheduling.Booking.SlotGenerator do
  @moduledoc """
  Expands `Scheduling.Booking.AvailabilityRule`s into concrete
  `Scheduling.Booking.Slot`s over a date range.

  A rule says *"Room 3, Mondays, 09:00–17:00, 20-minute slots"* in the office's
  **local wall time**. Generation resolves that against real dates, through the
  office's `timezone`, into UTC instants.

  ## Generation is additive and never destroys

  Insertion is `on_conflict: :nothing` against the `(office_id, starts_at)`
  unique index, which gives three properties at once:

    * **Idempotent.** A second pass conflicts with what is already there and
      changes nothing, so the job can run on a schedule and by hand without
      coordination.
    * **Booked and blocked slots survive.** The existing row is never touched,
      so a regeneration cannot cancel an appointment. This is the property that
      matters most; a job that silently dropped a booked slot would cancel
      someone's appointment with nothing to show for it.
    * **Retiring a rule stops new slots without removing old ones.**
      `AvailabilityRule.applies_on?/2` is the only definition of "in force" and
      is asked per day; slots already produced simply stay.

  Nothing here deletes. The consequence, stated plainly: **shortening a rule's
  window leaves the slots it already generated outside the new window in
  place**, still `:open` and still bookable. Pruning them would mean deleting
  slots, and a prune that got its predicate slightly wrong would delete booked
  ones — so it is deliberately out of scope here. Retiring the old rule and
  writing a new one is the supported way to change hours, and any prune should
  be a separate, explicitly `:open`-only operation.

  ## A slot's length is an absolute duration

  Only a slot's **start** is a local wall time. Its end is `slot_minutes` of
  real time after that instant, not the wall time one slot later.

  That is what "twenty minutes" means to the person sitting in the room, and it
  keeps the DST handling below confined to one decision instead of two. It also
  saves a slot that wall-clock arithmetic would wrongly discard: on 2026-03-08
  the 01:00–02:00 local slot is a genuine, attendable hour (06:00Z to 07:00Z)
  even though "02:00 local" never occurs that day.

  ## Daylight saving

  This is the reason the conversion happens here rather than being baked into
  the rule. `DateTime.new/4` reports both awkward cases and neither may crash:

    * **Spring forward** — the local time does not exist. On 2026-03-08 in
      `America/New_York`, 02:00–03:00 never happens, and `DateTime.new/4`
      returns `{:gap, _, _}`. Those slots are **skipped**: a slot at a time
      that never occurs cannot be attended, and materialising one would put an
      unattendable appointment on the calendar.

    * **Fall back** — the local time happens twice. On 2026-11-01, 01:00–02:00
      occurs once in EDT and again in EST, and `DateTime.new/4` returns
      `{:ambiguous, first, second}`. We take the **first** (the earlier
      instant). Generating both would double the room's capacity for an hour
      once a year; dropping both would lose an hour of real availability. One
      is the only defensible answer, and the earlier one is the one a person
      reading a clock would arrive for.

  ## Overlapping rules

  Two rules for one office covering the same instant are a configuration
  error, not something to resolve silently. They are detected **before**
  insertion by grouping candidates on their start instant: any instant claimed
  by more than one rule is a conflict.

  The earliest rule by id wins — deterministic, so a regeneration does not
  shuffle the calendar — and the conflict is returned in the result and logged.
  Letting the unique index absorb it instead would work, but would hide a real
  data-entry mistake behind behaviour that looks correct.
  """

  require Logger

  import Ecto.Query, warn: false

  alias Scheduling.Booking
  alias Scheduling.Booking.AvailabilityRule
  alias Scheduling.Booking.Slot
  alias Scheduling.Offices.Office
  alias Scheduling.Repo

  @typedoc """
  What a generation pass did.

  `conflicts` names instants claimed by more than one rule — a configuration
  error worth surfacing, not a failure.
  """
  @type result :: %{
          created: non_neg_integer(),
          skipped_gap: non_neg_integer(),
          conflicts: [%{office_id: integer(), starts_at: DateTime.t(), rule_ids: [integer()]}]
        }

  @doc """
  Generates slots for one office across `from`..`to` inclusive.

  The office's `timezone` drives the conversion, so it must be loaded.
  """
  @spec generate_for_office(Office.t(), Date.t(), Date.t()) :: result()
  def generate_for_office(%Office{} = office, %Date{} = from, %Date{} = to) do
    {candidates, skipped_gap} = candidates_for(office, from, to)
    {keep, conflicts} = resolve_conflicts(candidates)

    log_conflicts(conflicts)

    %{created: insert(keep), skipped_gap: skipped_gap, conflicts: conflicts}
  end

  @doc """
  Generates slots for every office across `from`..`to` inclusive.

  Results are summed; conflicts from all offices are concatenated.
  """
  @spec generate_all(Date.t(), Date.t()) :: result()
  def generate_all(%Date{} = from, %Date{} = to) do
    Office
    |> Repo.all()
    |> Enum.map(&generate_for_office(&1, from, to))
    |> Enum.reduce(%{created: 0, skipped_gap: 0, conflicts: []}, fn r, acc ->
      %{
        created: acc.created + r.created,
        skipped_gap: acc.skipped_gap + r.skipped_gap,
        conflicts: acc.conflicts ++ r.conflicts
      }
    end)
  end

  @doc """
  Tops the rolling horizon up: today through `Booking.horizon_days/0` ahead.

  Additive, so running it daily simply extends the far edge.
  """
  @spec generate_horizon() :: result()
  def generate_horizon do
    today = Date.utc_today()
    generate_all(today, Date.add(today, Booking.horizon_days()))
  end

  # --- candidate expansion ---------------------------------------------------

  defp candidates_for(%Office{} = office, from, to) do
    from
    |> Date.range(to)
    |> Enum.flat_map(&day_candidates(office, &1))
    |> Enum.split_with(&(&1 != :gap))
    |> then(fn {kept, gaps} -> {kept, length(gaps)} end)
  end

  defp day_candidates(%Office{} = office, %Date{} = date) do
    office.id
    |> Booking.rules_in_force(date)
    |> Enum.flat_map(&rule_candidates(&1, office, date))
  end

  defp rule_candidates(%AvailabilityRule{} = rule, %Office{} = office, %Date{} = date) do
    count = AvailabilityRule.slot_count(rule)

    Enum.map(0..(count - 1)//1, fn index ->
      offset = index * rule.slot_minutes

      case local_instant(date, rule.starts_at, offset, office.timezone) do
        {:ok, starts_at} ->
          %{
            office_id: office.id,
            availability_rule_id: rule.id,
            starts_at: starts_at,
            # An absolute duration from the resolved start, NOT the local wall
            # time one slot later. A twenty-minute slot is twenty real minutes
            # for the person sitting in the room.
            #
            # This also matters at a spring-forward boundary. On 2026-03-08 the
            # 01:00–02:00 local slot is a genuine, attendable hour (06:00Z to
            # 07:00Z) even though "02:00 local" never occurs — resolving the
            # end as a wall time would find a gap and discard a slot that is
            # perfectly real.
            ends_at: DateTime.add(starts_at, rule.slot_minutes * 60, :second)
          }

        :gap ->
          :gap
      end
    end)
  end

  # Resolve a local wall time to a UTC instant. The whole DST story lives here.
  defp local_instant(%Date{} = date, %Time{} = base, offset_minutes, timezone) do
    naive =
      date
      |> NaiveDateTime.new!(base)
      |> NaiveDateTime.add(offset_minutes * 60, :second)

    case DateTime.new(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), timezone) do
      {:ok, dt} ->
        {:ok, to_utc(dt)}

      # Fall back: the wall time happens twice. Take the earlier instant.
      {:ambiguous, first, _second} ->
        {:ok, to_utc(first)}

      # Spring forward: the wall time never happens. Nothing to generate.
      {:gap, _before, _after} ->
        :gap

      {:error, _reason} ->
        :gap
    end
  end

  defp to_utc(%DateTime{} = dt) do
    dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
  end

  # --- conflicts -------------------------------------------------------------

  # Two rules for one office claiming the same instant. Deterministic winner:
  # the earliest rule by id, so regeneration does not reshuffle the calendar.
  defp resolve_conflicts(candidates) do
    candidates
    |> Enum.group_by(&{&1.office_id, &1.starts_at})
    |> Enum.reduce({[], []}, fn {{office_id, starts_at}, group}, {keep, conflicts} ->
      case group do
        [single] ->
          {[single | keep], conflicts}

        many ->
          winner = Enum.min_by(many, & &1.availability_rule_id)

          conflict = %{
            office_id: office_id,
            starts_at: starts_at,
            rule_ids: many |> Enum.map(& &1.availability_rule_id) |> Enum.sort()
          }

          {[winner | keep], [conflict | conflicts]}
      end
    end)
    |> then(fn {keep, conflicts} ->
      {Enum.sort_by(keep, & &1.starts_at, DateTime),
       Enum.sort_by(conflicts, & &1.starts_at, DateTime)}
    end)
  end

  defp log_conflicts([]), do: :ok

  defp log_conflicts(conflicts) do
    # charlists: :as_lists because rule ids are small integers, and the default
    # inspect would render [33, 34] as ~c"!\"" — unreadable in the one place
    # someone is trying to find which rules collided.
    Logger.warning(
      "Slot generation found #{length(conflicts)} overlapping availability rule(s). " <>
        "The lowest rule id wins each instant. First: " <>
        inspect(hd(conflicts), charlists: :as_lists)
    )
  end

  # --- insertion -------------------------------------------------------------

  defp insert([]), do: 0

  defp insert(candidates) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(candidates, fn c ->
        c
        |> Map.put(:status, :open)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    # on_conflict: :nothing is what makes this idempotent AND what protects
    # booked and blocked slots — the existing row is left exactly as it is.
    {count, _} =
      Repo.insert_all(Slot, rows,
        on_conflict: :nothing,
        conflict_target: [:office_id, :starts_at]
      )

    count
  end
end
