defmodule Scheduling.Idempotency.Sweeper do
  @moduledoc """
  Periodically drops idempotency keys past their retention window.

  Pure hygiene, and not optional: without it the table grows by a row for every
  write that carried an `Idempotency-Key` and never shrinks. That is a table
  written to on the hot path of exactly the integrations this feature exists
  for.

  Hourly, matching `Scheduling.Auth.SessionRevocation.Sweeper` — the rows it
  removes are already past honouring, so sweeping late costs only disk.

  It also clears **abandoned claims**: a request that died between claiming a
  key and settling it leaves a row with no response, and that row would
  otherwise answer `409 in_progress` to every retry forever. The sweep is the
  only thing that releases it, which is why this runs whether or not anyone is
  using the feature.
  """

  use GenServer

  require Logger

  alias Scheduling.Idempotency

  @interval_ms :timer.hours(1)

  @doc "Child spec for the sweeper, or `nil` when it is switched off."
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(enabled?(), do: __MODULE__)

  @doc "Whether the sweeper should run. On unless configured otherwise."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:scheduling, Scheduling.Idempotency, [])
    |> Keyword.get(:sweeper_enabled, true)
  end

  @doc "How long between sweeps. Configurable so a test can drive one."
  @spec interval_ms() :: pos_integer()
  def interval_ms do
    Application.get_env(:scheduling, Scheduling.Idempotency, [])
    |> Keyword.get(:sweep_interval_ms, @interval_ms)
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts), do: {:ok, schedule(%{timer: nil}), {:continue, :sweep}}

  @impl GenServer
  def handle_continue(:sweep, state) do
    sweep()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, schedule(state)}
  end

  defp sweep do
    case Idempotency.delete_expired() do
      0 -> :ok
      count -> Logger.info("Swept #{count} expired idempotency key(s)")
    end
  rescue
    # A failed sweep is disk, not correctness. Taking the supervisor down over
    # it would trade a slow leak for an outage.
    error ->
      Logger.error("Idempotency sweep failed: #{Exception.message(error)}")
      :error
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer, info: false)
    %{state | timer: Process.send_after(self(), :sweep, interval_ms())}
  end
end
