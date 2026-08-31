defmodule Scheduling.Booking.SlotPruner do
  @moduledoc """
  Removes slots the availability rules no longer justify.

  Generation is additive: shortening a rule's window, or retiring one, leaves
  the slots it already produced in place — still `:open`, still bookable. A
  room goes on offering times it no longer works, and nothing says so. This is
  the other half.

  ## It only ever deletes an unbooked, unblocked slot

  That is the whole safety argument, and it is enforced twice.

  A `:booked` slot must survive even when the rules stopped producing it —
  deleting one would cancel somebody's appointment with no record and no
  message. A `:blocked` slot must survive too: it was withheld deliberately,
  and quietly returning it to service is the opposite of what someone asked
  for.

  So the delete filters on `status == :open` **and** `is_nil(appointment_id)`
  in SQL. The second is redundant while `book/1` writes both together, and it
  stays because "redundant" and "load-bearing if that ever changes" are the
  same thing here. `docs/booking.md` records why this was left out of BK-2
  rather than shipped half-done: a predicate slightly wrong here deletes
  bookings.

  ## Pruning is safe to run automatically *because* of that

  Everything it can remove is unbooked capacity that the current rules do not
  justify, and regenerating puts it straight back. A rule deactivated by
  mistake therefore costs a regeneration, not a lost appointment — which is why
  it is wired into `Scheduling.Booking.HorizonKeeper` by default rather than
  left as a command nobody remembers to run.

  Set `BOOKING_PRUNE_STALE_SLOTS=false` to disable it.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Scheduling.Booking
  alias Scheduling.Booking.Slot
  alias Scheduling.Booking.SlotGenerator
  alias Scheduling.Offices.Office
  alias Scheduling.Repo

  @typedoc """
  What a prune removed, what it left alone because it was booked or blocked,
  and what it refused to touch because the office's rules read as empty.
  """
  @type result :: %{
          deleted: non_neg_integer(),
          protected: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Removes stale open slots for one office across `from`..`to` inclusive.

  Stale means: inside the window, and not among the instants the office's
  current rules would generate for those dates.

  ## The empty-rules guard

  If the office's rules produce **no** candidates at all, this skips the office
  entirely unless `allow_empty: true`.

  "The rules justify nothing" and "we failed to read the rules" produce the
  same empty set, and the safe reading is the second. Without the guard, a
  transient condition that made rule loading return nothing — a bad migration
  state, an accidental mass-deactivation, a query that legitimately finds none
  because a date boundary moved — would delete **every open slot in the
  horizon** on the very next keeper tick. Booked slots would survive, but
  nobody could book anything until the rules came back *and* generation ran.

  That risk was acceptable when pruning was something you ran deliberately. It
  is not, now that it runs after every horizon pass.

  A genuinely retired office therefore keeps its stale open slots under
  automatic pruning. Clearing those is a deliberate act:
  `prune_for_office(office, from, to, allow_empty: true)`.
  """
  @spec prune_for_office(Office.t(), Date.t(), Date.t(), keyword()) :: result()
  def prune_for_office(%Office{} = office, %Date{} = from, %Date{} = to, opts \\ []) do
    wanted = SlotGenerator.candidate_starts(office, from, to)
    {window_start, window_end} = window(from, to)

    if MapSet.size(wanted) == 0 and not Keyword.get(opts, :allow_empty, false) do
      skip_empty(office, window_start, window_end)
    else
      do_prune(office, wanted, window_start, window_end)
    end
  end

  defp skip_empty(office, window_start, window_end) do
    open_count =
      Slot
      |> where([s], s.office_id == ^office.id)
      |> where([s], s.starts_at >= ^window_start and s.starts_at < ^window_end)
      |> where([s], s.status == :open and is_nil(s.appointment_id))
      |> Repo.aggregate(:count)

    if open_count > 0 do
      Logger.warning(
        "Skipped pruning #{office.name}: its rules produce no slots at all, and " <>
          "#{open_count} open slot(s) exist. Refusing to delete them automatically — " <>
          "an unreadable rule set looks identical to a retired one. " <>
          "Prune with allow_empty: true if the office really is closed."
      )
    end

    %{deleted: 0, protected: 0, skipped: open_count}
  end

  defp do_prune(%Office{} = office, wanted, window_start, window_end) do
    stale =
      Slot
      |> where([s], s.office_id == ^office.id)
      |> where([s], s.starts_at >= ^window_start and s.starts_at < ^window_end)
      # The two guards. See the moduledoc.
      |> where([s], s.status == :open and is_nil(s.appointment_id))
      |> select([s], %{id: s.id, starts_at: s.starts_at})
      |> Repo.all()
      |> Enum.reject(&MapSet.member?(wanted, &1.starts_at))

    protected = protected_count(office.id, window_start, window_end, wanted)
    delete(stale, office, protected)
  end

  @doc "Prunes every office across `from`..`to` inclusive."
  @spec prune_all(Date.t(), Date.t()) :: result()
  def prune_all(%Date{} = from, %Date{} = to) do
    Office
    |> Repo.all()
    |> Enum.map(&prune_for_office(&1, from, to))
    |> Enum.reduce(%{deleted: 0, protected: 0, skipped: 0}, fn r, acc ->
      %{
        deleted: acc.deleted + r.deleted,
        protected: acc.protected + r.protected,
        skipped: acc.skipped + r.skipped
      }
    end)
  end

  @doc "Prunes across the same horizon generation fills: today through `horizon_days/0`."
  @spec prune_horizon() :: result()
  def prune_horizon do
    today = Date.utc_today()
    prune_all(today, Date.add(today, Booking.horizon_days()))
  end

  @doc """
  Whether the horizon keeper should prune after generating.

  On by default: the only thing pruning can remove is unbooked capacity the
  rules no longer justify, and regeneration restores it.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:scheduling, Scheduling.Booking, [])
    |> Keyword.get(:prune_stale_slots, true)
  end

  defp delete([], _office, protected), do: %{deleted: 0, protected: protected, skipped: 0}

  defp delete(stale, office, protected) do
    ids = Enum.map(stale, & &1.id)

    # Re-asserted at the point of deletion rather than trusting the ids we
    # selected: between the read and the write, one of them may have been
    # booked.
    {deleted, _} =
      Slot
      |> where([s], s.id in ^ids and s.status == :open and is_nil(s.appointment_id))
      |> Repo.delete_all()

    if deleted > 0 do
      Logger.info(
        "Pruned #{deleted} stale open slot(s) from #{office.name}; " <>
          "#{protected} booked or blocked slot(s) left in place"
      )
    end

    %{deleted: deleted, protected: protected, skipped: 0}
  end

  # Slots the rules no longer justify but which are booked or blocked. Counted
  # so the report can say what was spared, which is the number someone chasing
  # "why does this room still show Monday evening" actually needs.
  defp protected_count(office_id, window_start, window_end, wanted) do
    Slot
    |> where([s], s.office_id == ^office_id)
    |> where([s], s.starts_at >= ^window_start and s.starts_at < ^window_end)
    |> where([s], s.status != :open or not is_nil(s.appointment_id))
    |> select([s], s.starts_at)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(wanted, &1))
    |> length()
  end

  # Dates are inclusive; slots are instants. The window runs from the start of
  # `from` to the start of the day after `to`, in UTC — generation stores UTC,
  # so comparing in UTC is comparing like with like.
  defp window(from, to) do
    {
      DateTime.new!(from, ~T[00:00:00], "Etc/UTC"),
      DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC")
    }
  end
end
