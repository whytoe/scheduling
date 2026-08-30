defmodule Scheduling.Booking.AvailabilityRule do
  @moduledoc """
  A recurring statement of when an office is bookable:
  *"Room 3, Mondays, 09:00–17:00, 20-minute slots"*.

  Rules are the input to slot generation. They describe a repeating weekly
  pattern; slots are the concrete instants that pattern produces.

  ## Times are local wall time

  `starts_at` and `ends_at` are `Time` values in the **office's** timezone,
  with no offset. "09:00" means nine in the morning where the room is, and it
  has to keep meaning that across a DST transition — so the conversion to an
  instant happens at generation, through `Scheduling.Offices.Office.timezone`.

  Storing an offset here would freeze it at whatever it was the day the rule
  was written, and the calendar would drift by an hour twice a year. See
  `docs/booking.md`.

  ## A rule is superseded, not edited

  `effective_from` / `effective_until` bound a rule's life. Changing a room's
  hours means ending the old rule and writing a new one, so slots already
  generated under the old pattern stay explicable. Editing in place would
  silently rewrite what the calendar meant last month.

  ## Windows that do not divide evenly

  A 09:00–17:00 window with 50-minute slots yields nine whole slots and a
  50-minute remainder. The remainder is **dropped**, not rounded up into a
  short slot: a short slot is one an appointment cannot actually fit into, and
  offering it would produce bookings that overrun the window. `slot_count/1`
  is the authority on how many a rule yields, and it floors.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Scheduling.Offices.Office

  @type t :: %__MODULE__{}

  # 1 = Monday .. 7 = Sunday, matching Date.day_of_week/1 so generation can
  # compare without a translation table.
  @days 1..7

  schema "availability_rules" do
    field :day_of_week, :integer
    field :starts_at, :time
    field :ends_at, :time
    field :slot_minutes, :integer
    field :effective_from, :date
    field :effective_until, :date
    field :active, :boolean, default: true

    belongs_to :office, Office

    timestamps(type: :utc_datetime)
  end

  @doc "Valid `day_of_week` values — 1 = Monday, 7 = Sunday, as `Date.day_of_week/1`."
  @spec days() :: Range.t()
  def days, do: @days

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :office_id,
      :day_of_week,
      :starts_at,
      :ends_at,
      :slot_minutes,
      :effective_from,
      :effective_until,
      :active
    ])
    |> validate_required([
      :office_id,
      :day_of_week,
      :starts_at,
      :ends_at,
      :slot_minutes,
      :effective_from
    ])
    |> validate_inclusion(:day_of_week, @days)
    # An hour is already a long appointment; a whole day is a data-entry slip.
    |> validate_number(:slot_minutes, greater_than: 0, less_than_or_equal_to: 480)
    |> validate_window()
    |> validate_effective_range()
    |> validate_fits_at_least_one_slot()
    |> assoc_constraint(:office)
  end

  @doc """
  How many whole slots this rule yields on a day it applies to.

  Floors: a trailing remainder shorter than `slot_minutes` is dropped rather
  than offered as a short slot, because an appointment booked into one would
  overrun the window.
  """
  @spec slot_count(t()) :: non_neg_integer()
  def slot_count(%__MODULE__{} = rule), do: div(window_minutes(rule), rule.slot_minutes)

  @doc "Length of the bookable window in minutes."
  @spec window_minutes(t()) :: integer()
  def window_minutes(%__MODULE__{starts_at: starts_at, ends_at: ends_at}) do
    div(Time.diff(ends_at, starts_at, :second), 60)
  end

  @doc """
  True when the rule is in force on `date` — active, the right weekday, and
  inside its effective range.

  Generation asks this per candidate day.
  """
  @spec applies_on?(t(), Date.t()) :: boolean()
  def applies_on?(%__MODULE__{active: false}, _date), do: false

  def applies_on?(%__MODULE__{} = rule, %Date{} = date) do
    Date.day_of_week(date) == rule.day_of_week and
      Date.compare(date, rule.effective_from) != :lt and
      not after_effective_until?(rule, date)
  end

  defp after_effective_until?(%__MODULE__{effective_until: nil}, _date), do: false

  defp after_effective_until?(%__MODULE__{effective_until: until}, date),
    do: Date.compare(date, until) == :gt

  # A window is a single same-day span. Overnight availability would need two
  # rules, which is clearer than a span whose end is "before" its start.
  defp validate_window(changeset) do
    with %Time{} = starts_at <- get_field(changeset, :starts_at),
         %Time{} = ends_at <- get_field(changeset, :ends_at) do
      case Time.compare(ends_at, starts_at) do
        :gt -> changeset
        _ -> add_error(changeset, :ends_at, "must be after the start time")
      end
    else
      _ -> changeset
    end
  end

  defp validate_effective_range(changeset) do
    with %Date{} = from <- get_field(changeset, :effective_from),
         %Date{} = until <- get_field(changeset, :effective_until) do
      case Date.compare(until, from) do
        :lt ->
          add_error(changeset, :effective_until, "must not be before the effective-from date")

        _ ->
          changeset
      end
    else
      _ -> changeset
    end
  end

  # A rule that yields no whole slot is bookable-in-name-only, and would sit in
  # the calendar generating nothing. Reject it at write time rather than
  # leaving someone to wonder why their room never has availability.
  defp validate_fits_at_least_one_slot(changeset) do
    with %Time{} = starts_at <- get_field(changeset, :starts_at),
         %Time{} = ends_at <- get_field(changeset, :ends_at),
         slot_minutes when is_integer(slot_minutes) and slot_minutes > 0 <-
           get_field(changeset, :slot_minutes),
         true <- Time.compare(ends_at, starts_at) == :gt do
      window = div(Time.diff(ends_at, starts_at, :second), 60)

      if window >= slot_minutes do
        changeset
      else
        add_error(
          changeset,
          :slot_minutes,
          "is longer than the window (#{window} minutes), so the rule would yield no slots"
        )
      end
    else
      _ -> changeset
    end
  end
end
