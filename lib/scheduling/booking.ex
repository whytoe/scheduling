defmodule Scheduling.Booking do
  @moduledoc """
  Booking: what is bookable, and (later) what has been booked.

  Today this covers **availability rules** — the recurring weekly patterns —
  and the **slots** they expand into. Appointments follow; see
  `docs/booking.md` for the whole shape.

  Booking sits beside the live-queue engine rather than replacing it. A booking
  reserves time; the matcher still decides which room, unless the service is
  uniquely routable — see the binding rules in `docs/booking.md`.
  """
  import Ecto.Query, warn: false

  alias Scheduling.Booking.Appointment
  alias Scheduling.Booking.AvailabilityRule
  alias Scheduling.Booking.Engine
  alias Scheduling.Booking.Slot
  alias Scheduling.Booking.SlotGenerator
  alias Scheduling.Repo

  @doc """
  Lists availability rules, newest first.

  Opts:

    * `:office_id` — only this office's rules
    * `:active` — only active (`true`) or only inactive (`false`) rules
  """
  @spec list_availability_rules(keyword()) :: [AvailabilityRule.t()]
  def list_availability_rules(opts \\ []) do
    AvailabilityRule
    |> filter_by_office(Keyword.get(opts, :office_id))
    |> filter_by_active(Keyword.get(opts, :active))
    |> order_by([r], asc: r.day_of_week, asc: r.starts_at, asc: r.id)
    |> preload(:office)
    |> Repo.all()
  end

  @doc "Fetches a rule with its office preloaded. Raises if missing."
  @spec get_availability_rule!(term()) :: AvailabilityRule.t()
  def get_availability_rule!(id) do
    AvailabilityRule |> Repo.get!(id) |> Repo.preload(:office)
  end

  @doc "Creates an availability rule."
  @spec create_availability_rule(map()) ::
          {:ok, AvailabilityRule.t()} | {:error, Ecto.Changeset.t()}
  def create_availability_rule(attrs \\ %{}) do
    %AvailabilityRule{}
    |> AvailabilityRule.changeset(attrs)
    |> Repo.insert()
    |> preload_office()
  end

  @doc """
  Updates an availability rule.

  Note the intended workflow for a *schedule change* is to end the old rule
  (`effective_until`) and write a new one, not to edit in place — see
  `Scheduling.Booking.AvailabilityRule`. This exists for corrections.
  """
  @spec update_availability_rule(AvailabilityRule.t(), map()) ::
          {:ok, AvailabilityRule.t()} | {:error, Ecto.Changeset.t()}
  def update_availability_rule(%AvailabilityRule{} = rule, attrs) do
    rule
    |> AvailabilityRule.changeset(attrs)
    |> Repo.update()
    |> preload_office()
  end

  @doc """
  Retires a rule from `on` onward by setting `effective_until`, leaving the
  slots it already produced explicable.

  Deleting a rule outright would orphan generated slots and erase why they
  exist; `delete_availability_rule/1` is there for a rule created in error.

  `on` is **clamped forward to the rule's own `effective_from`**. A rule
  scheduled to start next month cannot end today — the changeset refuses an
  `effective_until` before the `effective_from`, so without this, retiring a
  future-dated rule fails validation. The rule is deactivated either way
  (`AvailabilityRule.applies_on?/2` short-circuits on `active`), so clamping
  keeps the dates coherent without changing the outcome.

  Retiring "as of" a date is a statement about when the rule stops applying,
  not a claim that it ever applied before then.
  """
  @spec retire_availability_rule(AvailabilityRule.t(), Date.t()) ::
          {:ok, AvailabilityRule.t()} | {:error, Ecto.Changeset.t()}
  def retire_availability_rule(%AvailabilityRule{} = rule, %Date{} = on) do
    update_availability_rule(rule, %{effective_until: clamp_retire_date(rule, on), active: false})
  end

  defp clamp_retire_date(%AvailabilityRule{effective_from: from}, on) do
    if Date.compare(on, from) == :lt, do: from, else: on
  end

  @doc "Deletes a rule. For one created in error — prefer `retire_availability_rule/2`."
  @spec delete_availability_rule(AvailabilityRule.t()) ::
          {:ok, AvailabilityRule.t()} | {:error, Ecto.Changeset.t()}
  def delete_availability_rule(%AvailabilityRule{} = rule), do: Repo.delete(rule)

  @doc "Returns a changeset for form tracking."
  @spec change_availability_rule(AvailabilityRule.t(), map()) :: Ecto.Changeset.t()
  def change_availability_rule(%AvailabilityRule{} = rule, attrs \\ %{}) do
    AvailabilityRule.changeset(rule, attrs)
  end

  @doc """
  The rules in force for an office on a given date.

  This is what generation asks per candidate day. Filtering happens in Elixir
  rather than SQL because `applies_on?/2` is the single definition of "in
  force" — duplicating that logic as a query would give two answers to drift
  apart.
  """
  @spec rules_in_force(integer(), Date.t()) :: [AvailabilityRule.t()]
  def rules_in_force(office_id, %Date{} = date) do
    office_id
    |> then(&list_availability_rules(office_id: &1, active: true))
    |> Enum.filter(&AvailabilityRule.applies_on?(&1, date))
  end

  # --- slots -----------------------------------------------------------------

  @default_horizon_days 60

  @doc """
  How many days ahead the rolling horizon is kept topped up.

  Configure with `config :scheduling, Scheduling.Booking, horizon_days: n`.
  Sixty days is far enough to book a couple of months out and short enough
  that a schedule change does not leave a year of stale slots behind — nothing
  prunes them (see `Scheduling.Booking.SlotGenerator`), so the horizon is also
  the blast radius of a mistake.
  """
  @spec horizon_days() :: pos_integer()
  def horizon_days do
    Application.get_env(:scheduling, __MODULE__, [])[:horizon_days] || @default_horizon_days
  end

  @doc """
  Lists slots.

  Opts: `:office_id`, `:status` (atom or list), `:from` / `:to` (`DateTime`
  bounds on `starts_at`, `from` inclusive and `to` exclusive).
  """
  @spec list_slots(keyword()) :: [Slot.t()]
  def list_slots(opts \\ []) do
    Slot
    |> filter_slots_by_office(Keyword.get(opts, :office_id))
    |> filter_by_status(Keyword.get(opts, :status))
    |> filter_from(Keyword.get(opts, :from))
    |> filter_to(Keyword.get(opts, :to))
    |> order_by([s], asc: s.starts_at, asc: s.office_id)
    |> Repo.all()
  end

  @doc "Fetches a slot. Raises if missing."
  @spec get_slot!(term()) :: Slot.t()
  def get_slot!(id), do: Repo.get!(Slot, id)

  @doc """
  Generates slots for one office across a date range, inclusive.

  Additive and idempotent — see `Scheduling.Booking.SlotGenerator` for what
  that guarantees and what it deliberately does not do.
  """
  @spec generate_slots(Scheduling.Offices.Office.t(), Date.t(), Date.t()) ::
          SlotGenerator.result()
  defdelegate generate_slots(office, from, to), to: SlotGenerator, as: :generate_for_office

  @doc "Generates slots for every office across a date range, inclusive."
  @spec generate_all_slots(Date.t(), Date.t()) :: SlotGenerator.result()
  defdelegate generate_all_slots(from, to), to: SlotGenerator, as: :generate_all

  @doc "Tops the rolling horizon up: today through `horizon_days/0` ahead."
  @spec generate_horizon() :: SlotGenerator.result()
  defdelegate generate_horizon(), to: SlotGenerator

  @doc """
  Withholds a slot from booking — a room closed for cleaning, a one-off
  absence.

  Refuses a booked slot: cancel the appointment first. See
  `Scheduling.Booking.Slot.block_changeset/1`.
  """
  @spec block_slot(Slot.t()) :: {:ok, Slot.t()} | {:error, Ecto.Changeset.t()}
  def block_slot(%Slot{} = slot), do: slot |> Slot.block_changeset() |> Repo.update()

  @doc "Returns a blocked slot to `:open`. Refuses a booked slot."
  @spec unblock_slot(Slot.t()) :: {:ok, Slot.t()} | {:error, Ecto.Changeset.t()}
  def unblock_slot(%Slot{} = slot), do: slot |> Slot.unblock_changeset() |> Repo.update()

  # --- appointments ----------------------------------------------------------

  @doc """
  Books an appointment. See `Scheduling.Booking.Engine` for the five steps and,
  more importantly, why reservation is a compare-and-swap rather than a
  select-then-update.
  """
  @spec book(map()) :: {:ok, Appointment.t()} | {:error, Engine.error()}
  defdelegate book(attrs), to: Engine

  @doc "Fetches an appointment with patient, slots and capabilities preloaded."
  @spec get_appointment!(term()) :: Appointment.t()
  def get_appointment!(id) do
    Appointment |> Repo.get!(id) |> Repo.preload([:patient, :slots, :required_capabilities])
  end

  @doc """
  Lists appointments, soonest first.

  Opts: `:patient_id`, `:status` (atom or list).
  """
  @spec list_appointments(keyword()) :: [Appointment.t()]
  def list_appointments(opts \\ []) do
    Appointment
    |> filter_appointments_by_patient(Keyword.get(opts, :patient_id))
    |> filter_appointments_by_status(Keyword.get(opts, :status))
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> preload([:patient, :slots, :required_capabilities])
    |> Repo.all()
  end

  defp filter_appointments_by_patient(query, nil), do: query

  defp filter_appointments_by_patient(query, patient_id),
    do: where(query, [a], a.patient_id == ^patient_id)

  defp filter_appointments_by_status(query, nil), do: query

  defp filter_appointments_by_status(query, statuses) when is_list(statuses),
    do: where(query, [a], a.status in ^statuses)

  defp filter_appointments_by_status(query, status),
    do: where(query, [a], a.status == ^status)

  defp filter_by_office(query, nil), do: query
  defp filter_by_office(query, office_id), do: where(query, [r], r.office_id == ^office_id)

  defp filter_by_active(query, nil), do: query
  defp filter_by_active(query, active), do: where(query, [r], r.active == ^active)

  defp filter_slots_by_office(query, nil), do: query
  defp filter_slots_by_office(query, office_id), do: where(query, [s], s.office_id == ^office_id)

  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, statuses) when is_list(statuses),
    do: where(query, [s], s.status in ^statuses)

  defp filter_by_status(query, status), do: where(query, [s], s.status == ^status)

  defp filter_from(query, nil), do: query
  defp filter_from(query, %DateTime{} = from), do: where(query, [s], s.starts_at >= ^from)

  defp filter_to(query, nil), do: query
  defp filter_to(query, %DateTime{} = to), do: where(query, [s], s.starts_at < ^to)

  defp preload_office({:ok, rule}), do: {:ok, Repo.preload(rule, :office)}
  defp preload_office(other), do: other
end
