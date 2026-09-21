defmodule Scheduling.Webhooks.Sweeper do
  @moduledoc """
  Drains the webhook delivery queue on an interval.

  `Scheduling.Webhooks.dispatch/1` enqueues a `Delivery` row per matching
  subscription; this is what actually sends them, retries the failures on a
  backoff, and dead-letters the ones that never land. Without it the queue is
  written and never read.

  The work lives in `Scheduling.Webhooks.deliver_due/1` — this is only the
  clock. Tests drive `deliver_due/1` directly and leave the GenServer off
  (`sweeper_enabled: false` in the test config), the same split
  `Scheduling.Idempotency.Sweeper` uses.

  Default interval is short (5s) because this is a delivery queue, not a
  retention sweep: a webhook that waited an hour to first send would be useless.
  Retries stretch out on their own via the per-delivery backoff.
  """

  use GenServer

  require Logger

  alias Scheduling.Webhooks

  @interval_ms :timer.seconds(5)

  @doc "Child spec for the sweeper, or `nil` when it is switched off."
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(enabled?(), do: __MODULE__)

  @doc "Whether the sweeper should run. On unless configured otherwise."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:scheduling, Webhooks, [])
    |> Keyword.get(:sweeper_enabled, true)
  end

  @doc "How long between drains. Configurable so a test can drive one."
  @spec interval_ms() :: pos_integer()
  def interval_ms do
    Application.get_env(:scheduling, Webhooks, [])
    |> Keyword.get(:sweep_interval_ms, @interval_ms)
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts), do: {:ok, schedule(%{timer: nil}), {:continue, :drain}}

  @impl GenServer
  def handle_continue(:drain, state) do
    drain()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:drain, state) do
    drain()
    {:noreply, schedule(state)}
  end

  defp drain do
    case Webhooks.deliver_due() do
      0 -> :ok
      count -> Logger.debug("Attempted #{count} webhook deliver(y/ies)")
    end
  rescue
    # A failed drain is a delayed webhook, not a corrupted one — the rows are
    # still there for the next tick. Taking the supervisor down over it would
    # be worse than the delay.
    error -> Logger.error("Webhook sweep failed: #{inspect(error)}")
  end

  defp schedule(state) do
    if ref = state[:timer], do: Process.cancel_timer(ref)
    %{state | timer: Process.send_after(self(), :drain, interval_ms())}
  end
end
