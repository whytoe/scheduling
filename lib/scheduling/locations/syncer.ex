defmodule Scheduling.Locations.Syncer do
  @moduledoc """
  Keeps the local site cache in step with ac-core.

  `Scheduling.Locations.sync_from_core/1` does the work; this decides when it
  runs. Without something calling it the `locations` table stays empty, and an
  empty table is not a neutral state — it silently disables per-office access
  control. `Scheduling.Auth.Scope.location_ids/1` resolves an operator's
  `astrum_location` claim, and `Scheduling.Offices.list_offices/1` matches it
  against `locations.core_location_id`. With no locations every office is
  unlinked, and unlinked offices are visible to everyone by design. So a
  deployment with no sync does not fail closed or open — it looks exactly like
  a working one while scoping nothing.

  That is the reason this is a supervised process rather than an admin button.
  A control that only works if someone remembers to press it is not a control.

  ## Timing

  The first pass is delayed briefly: `Scheduling.Auth.Provider` discovers the
  issuer asynchronously at boot, and a sync that starts before discovery lands
  just fails with `:provider_not_ready`. The delay avoids making that the
  normal case rather than relying on the retry to paper over it.

  A failed pass retries sooner than a successful one — starting 30s out,
  doubling, capped at the normal interval. ac-core being briefly unreachable
  should not mean stale sites for the full interval, and a longer outage should
  not mean hammering it.

  ## Failure

  A failure is logged and rescheduled, never raised. The site list going stale
  is worth an alert; it is not worth taking the supervisor — and with it the
  board — down over. The previous cache stays readable throughout, which is
  the whole point of projecting the registry locally.

  Disable with `LOCATION_SYNC_ENABLED=false`. Absent core credentials it does
  not start at all, which is the local-dev and test default.
  """

  use GenServer

  require Logger

  alias Scheduling.Core
  alias Scheduling.Locations

  @default_interval_ms :timer.hours(1)
  @initial_delay_ms :timer.seconds(5)
  @min_retry_ms :timer.seconds(30)

  @doc """
  Child spec for the syncer, or `nil` when it should not run.

  `Scheduling.Application` filters the nil out.
  """
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(enabled?(), do: __MODULE__)

  @doc """
  Whether the syncer should run.

  Requires core credentials — there is nothing to sync from without them — and
  can be switched off independently for a deployment that populates locations
  some other way.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Core.enabled?() and config(:sync_enabled, true)

  @doc "How long between successful passes."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: config(:sync_interval_ms, @default_interval_ms)

  @doc """
  How long after boot the first pass runs.

  Configurable so a test can drive a pass without waiting; nothing else should
  need to change it.
  """
  @spec initial_delay_ms() :: pos_integer()
  def initial_delay_ms, do: config(:sync_initial_delay_ms, @initial_delay_ms)

  @doc "The first retry delay after a failed pass. Doubles up to `interval_ms/0`."
  @spec min_retry_ms() :: pos_integer()
  def min_retry_ms, do: config(:sync_min_retry_ms, @min_retry_ms)

  defp config(key, default) do
    Application.get_env(:scheduling, Scheduling.Locations, []) |> Keyword.get(key, default)
  end

  @doc """
  Asks for a pass now rather than at the next interval.

  Fire-and-forget, and safe when the syncer is not running — a caller should
  not have to know whether it is.
  """
  @spec nudge() :: :ok
  def nudge do
    send(__MODULE__, :sync)
    :ok
  rescue
    # No such process: unconfigured, disabled, or a test.
    ArgumentError -> :ok
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    {:ok, schedule(%{timer: nil, backoff_ms: min_retry_ms(), runs: 0}, initial_delay_ms())}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    case sync() do
      :ok ->
        {:noreply, state |> reset_backoff() |> schedule(interval_ms())}

      :error ->
        {:noreply, schedule(state, state.backoff_ms) |> grow_backoff()}
    end
  end

  defp sync do
    case Locations.sync_from_core() do
      {:ok, result} ->
        # Logged every pass, not only on change: "the sync ran and found
        # nothing new" and "the sync has not run since Tuesday" are the two
        # states an operator most needs to tell apart, and silence cannot.
        Logger.info(
          "Location sync: #{result.upserted} upserted, " <>
            "#{result.deactivated} deactivated, #{result.pages} page(s)"
        )

        :ok

      {:error, reason} ->
        # sync_from_core/1 has already logged the detail.
        Logger.warning("Location sync did not complete: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.error("Location sync crashed: #{Exception.message(error)}")
      :error
  end

  # Cancels any pending timer first: nudge/0 while one is outstanding would
  # otherwise leave both running, and every nudge would add another for the
  # life of the process.
  defp schedule(state, delay_ms) do
    if state.timer, do: Process.cancel_timer(state.timer, info: false)

    %{state | timer: Process.send_after(self(), :sync, delay_ms), runs: state.runs + 1}
  end

  defp reset_backoff(state), do: %{state | backoff_ms: min_retry_ms()}

  defp grow_backoff(state),
    do: %{state | backoff_ms: min(state.backoff_ms * 2, interval_ms())}
end
