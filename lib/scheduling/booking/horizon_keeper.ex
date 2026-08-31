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

  ## It runs whether or not there are rules yet

  It used to stay out of the tree when no availability rules existed, checked
  once at boot. That saved a timer and cost something much worse: adding the
  **first** rule to a running system started nothing, so an admin created a
  rule, was told slots would generate, and got nothing — in exactly the
  situation where someone is setting the system up and has least reason to
  suspect a background process.

  A daily query that finds no rules is cheap. A silent dead end during setup is
  not, so the trade is now the other way round. With no rules, generation
  creates nothing and logs nothing.

  `nudge/0` also lets rule creation ask for a pass immediately, so the first
  rule produces slots in seconds rather than within a day. That is only
  possible because the process is now always alive — there was previously
  nothing to nudge.

  Disable with `BOOKING_HORIZON_KEEPER=false`; it is off in `:test`, where
  nothing should be querying outside a sandbox-owned connection.
  """

  use GenServer

  require Logger

  alias Scheduling.Booking
  alias Scheduling.Booking.SlotPruner

  @default_interval_ms :timer.hours(24)

  @doc """
  Child spec for the horizon keeper, or `nil` when it is switched off.

  Deliberately **not** conditional on rules existing — see the moduledoc.
  """
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(enabled?(), do: __MODULE__)

  @doc """
  How long between passes. Configurable so a test can drive several in a
  bounded time; nothing else should need to change it.
  """
  @spec interval_ms() :: pos_integer()
  def interval_ms do
    Application.get_env(:scheduling, Scheduling.Booking, [])
    |> Keyword.get(:horizon_interval_ms, @default_interval_ms)
  end

  @doc """
  Whether the keeper should run. On unless configured otherwise.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:scheduling, Scheduling.Booking, [])
    |> Keyword.get(:horizon_keeper_enabled, true)
  end

  @doc """
  Asks for a generation pass now instead of waiting for the next daily one.

  For the moment a rule is created or changed: the calendar should reflect it
  while the person who made the change is still looking at the screen.

  Fire-and-forget, and safe when the keeper is not running — a caller should
  not have to know whether it is. It does not wait for the pass to finish, so
  slots may appear a moment after the reply.
  """
  @spec nudge() :: :ok
  def nudge do
    send(__MODULE__, :generate)
    :ok
  rescue
    # No such process: the keeper is disabled, or this is a test.
    ArgumentError -> :ok
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    # Generate immediately: unlike sweeping, an empty horizon is a *missing
    # calendar*, not deferred hygiene. Waiting a day to fill it would leave a
    # freshly-booted deployment with nothing bookable.
    {:ok, %{timer: nil, runs: 0}, {:continue, :generate}}
  end

  @impl GenServer
  def handle_continue(:generate, state) do
    {:noreply, generate_and_schedule(state)}
  end

  @impl GenServer
  def handle_info(:generate, state) do
    {:noreply, generate_and_schedule(state)}
  end

  # Cancels the pending timer before setting the next one. Without this, every
  # `nudge/0` would leave the existing timer running *and* add another, so a
  # handful of rule edits would leave the keeper generating several times a
  # day for the life of the process — growing every time anyone touched a rule.
  defp generate_and_schedule(state) do
    generate()

    if state.timer, do: Process.cancel_timer(state.timer, info: false)

    %{
      state
      | timer: Process.send_after(self(), :generate, interval_ms()),
        # Counted so a test can tell one scheduled pass from a pile of leaked
        # ones. Orphaned timers are invisible from the outside — there is no
        # API for "how many timers does this process have pending" — so the
        # only way to observe the leak is to let them fire and count.
        runs: state.runs + 1
    }
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

    prune()

    result
  rescue
    error ->
      Logger.error("Slot horizon generation failed: #{Exception.message(error)}")
      :error
  end

  # After generating, remove what the rules no longer justify. Safe to run
  # unattended because it can only ever delete an unbooked, unblocked slot —
  # see Scheduling.Booking.SlotPruner. Anything removed in error comes back on
  # the next generation.
  #
  # Rescued separately: a prune failure must not make the generation that just
  # succeeded look like it failed.
  defp prune do
    if SlotPruner.enabled?(), do: SlotPruner.prune_horizon(), else: %{deleted: 0, protected: 0}
  rescue
    error ->
      Logger.error("Slot pruning failed: #{Exception.message(error)}")
      %{deleted: 0, protected: 0}
  end
end
