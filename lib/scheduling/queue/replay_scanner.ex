defmodule Scheduling.Queue.ReplayScanner do
  @moduledoc """
  Retries queue entries stuck in `:waiting` after a transient accept failure.

  When intake is unreachable for a while, or every office is momentarily full,
  accepts fail and the entries pile up `:waiting` with a `compliance_unavailable`
  or `no_eligible_office` rationale. When the cause clears, a clinician should
  not have to re-accept each one by hand (sc-ais). This is the clock that
  retries them.

  The work is `Scheduling.Queue.replay_pending/1` — this only paces it, the same
  split the other sweepers use. Tests drive `replay_pending/1` directly and
  leave the scanner off (`enabled: false` in the test config).

  Self-limiting: each pass is capped, and a retry that fails again simply stays
  `:waiting` for the next pass, so a still-down intake costs one bounded sweep,
  not a storm.
  """

  use GenServer

  require Logger

  alias Scheduling.Queue

  @interval_ms :timer.minutes(1)

  @doc "Child spec for the scanner, or `nil` when it is switched off."
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(enabled?(), do: __MODULE__)

  @doc "Whether the scanner should run. On unless configured otherwise."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:scheduling, __MODULE__, []) |> Keyword.get(:enabled, true)
  end

  @doc "How long between scans. Configurable so a test can drive one."
  @spec interval_ms() :: pos_integer()
  def interval_ms do
    Application.get_env(:scheduling, __MODULE__, []) |> Keyword.get(:interval_ms, @interval_ms)
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts), do: {:ok, schedule(%{timer: nil}), {:continue, :scan}}

  @impl GenServer
  def handle_continue(:scan, state) do
    scan()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:scan, state) do
    scan()
    {:noreply, schedule(state)}
  end

  defp scan do
    case Queue.replay_pending() do
      %{attempted: 0} ->
        :ok

      %{attempted: attempted, assigned: assigned} ->
        Logger.info("Replayed #{attempted} stuck queue entr(y/ies); #{assigned} now assigned")
    end
  rescue
    # A failed scan is a delayed retry, not a lost one — the entries are still
    # waiting for the next pass. Do not take the supervisor down over it.
    error -> Logger.error("Queue replay scan failed: #{inspect(error)}")
  end

  defp schedule(state) do
    if ref = state[:timer], do: Process.cancel_timer(ref)
    %{state | timer: Process.send_after(self(), :scan, interval_ms())}
  end
end
