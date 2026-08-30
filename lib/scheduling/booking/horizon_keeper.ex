defmodule Scheduling.Booking.HorizonKeeper do
  @moduledoc """
  Keeps the rolling slot horizon topped up.

  Availability rules describe a repeating pattern; slots are the concrete
  instants. Without something extending the far edge, the calendar would run
  out — bookable today, empty in two months, with nothing to explain why.

  Runs daily. Generation is additive and idempotent
  (`Scheduling.Booking.SlotGenerator`), so a pass that overlaps yesterday's
  costs a conflicting insert and changes nothing; the only effect of running
  late is that the horizon is briefly shorter than `Booking.horizon_days/0`.

  ## Why it is not always in the tree

  Absent unless slot generation has something to generate *from*, matching how
  `Scheduling.Auth.Provider` and `Scheduling.Auth.SessionRevocation.Sweeper`
  stay out of the tree when auth is unconfigured. A fresh checkout with no
  availability rules has no calendar to maintain, and a daily job that always
  finds nothing is noise in the supervision tree and in the logs.

  It is checked once, at boot. Adding the first availability rule to a running
  system therefore does not start it — generate by hand
  (`Booking.generate_horizon/0`) or restart. That is a deliberate simplicity
  trade: polling for the first rule would mean a timer that exists only to
  discover it has nothing to do.
  """

  use GenServer

  require Logger

  import Ecto.Query, warn: false

  alias Scheduling.Booking
  alias Scheduling.Booking.AvailabilityRule
  alias Scheduling.Repo

  @interval_ms :timer.hours(24)

  @doc """
  Child spec for the horizon keeper, or `nil` when there are no availability
  rules to generate from.
  """
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(any_rules?(), do: __MODULE__)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    # Generate immediately: unlike sweeping, an empty horizon is a *missing
    # calendar*, not deferred hygiene. Waiting a day to fill it would leave a
    # freshly-booted deployment with nothing bookable.
    {:ok, %{}, {:continue, :generate}}
  end

  @impl GenServer
  def handle_continue(:generate, state) do
    {:noreply, generate_and_schedule(state)}
  end

  @impl GenServer
  def handle_info(:generate, state) do
    {:noreply, generate_and_schedule(state)}
  end

  defp generate_and_schedule(state) do
    generate()
    Process.send_after(self(), :generate, @interval_ms)
    state
  end

  # A failure here must not take the supervisor down: the calendar being short
  # is bad, but a crash loop that also stops everything else is worse, and the
  # next pass will pick it up.
  defp generate do
    result = Booking.generate_horizon()

    if result.created > 0 or result.conflicts != [] do
      Logger.info(
        "Slot horizon: created #{result.created}, " <>
          "skipped #{result.skipped_gap} across a DST gap, " <>
          "#{length(result.conflicts)} overlapping rule(s)"
      )
    end

    result
  rescue
    error ->
      Logger.error("Slot horizon generation failed: #{Exception.message(error)}")
      :error
  end

  defp any_rules? do
    Repo.exists?(from r in AvailabilityRule, where: r.active == true)
  rescue
    # The tree is built before the repo is guaranteed usable in every
    # environment; a boot-time question that cannot be answered means "no".
    _error -> false
  end
end
