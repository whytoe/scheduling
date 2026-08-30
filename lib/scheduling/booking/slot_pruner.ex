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

  @typedoc "What a prune removed, and what it deliberately left alone."
  @type result :: %{deleted: non_neg_integer(), protected: non_neg_integer()}

  @doc """
  Removes stale open slots for one office across `from`..`to` inclusive.

  Stale means: inside the window, and not among the instants the office's
  current rules would generate for those dates.
  """
  @spec prune_for_office(Office.t(), Date.t(), Date.t()) :: result()
  def prune_for_office(%Office{} = office, %Date{} = from, %Date{} = to) do
    wanted = SlotGenerator.candidate_starts(office, from, to)
    {window_start, window_end} = window(from, to)

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
    |> Enum.reduce(%{deleted: 0, protected: 0}, fn r, acc ->
      %{deleted: acc.deleted + r.deleted, protected: acc.protected + r.protected}
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

  defp delete([], _office, protected), do: %{deleted: 0, protected: protected}

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

    %{deleted: deleted, protected: protected}
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
