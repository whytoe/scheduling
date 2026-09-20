defmodule Scheduling.Queue.Promoter do
  @moduledoc """
  Moves `:scheduled` entries to `:waiting` when their time arrives.

  The queueing service books a patient for 10:00 and tells us at 08:30. That
  entry must be invisible to the matcher until 10:00 — otherwise a patient is
  given a room ninety minutes early and a room is held for ninety minutes.

  ## Why a process rather than a clause in the query

  The cheaper implementation is to leave the status alone and have
  `list_waiting_entries/1` treat `scheduled AND scheduled_for <= now` as
  waiting. It was rejected, for two reasons that matter more than the saving:

    * **The status would lie.** The row would say `scheduled` while the system
      treated it as waiting, so the board, the API and the audit log would
      disagree with the behaviour. This codebase has been bitten repeatedly by
      state that reads as one thing and behaves as another.
    * **There would be no audit row.** Every other status change writes one.
      A transition that happens implicitly, inside a query, cannot.

  So the promotion is a real transition: it goes through the lifecycle table,
  writes `queue_entry.promoted`, and broadcasts to the board like any other.

  ## The failure mode, stated

  If this process is not running, scheduled entries never become waiting and
  those patients are never called. That is a silent failure of exactly the kind
  this module's own reasoning warns about — so a promotion is logged, and a
  failed pass is logged at error rather than swallowed. The matcher never picks
  up a `:scheduled` entry regardless, which means a stalled promoter delays
  patients rather than mis-routing them.

  Runs every minute. A clinic can absorb a patient appearing in the queue up to
  sixty seconds late; the alternative is a timer firing constantly to serve a
  column most rows leave null.
  """

  use GenServer

  require Logger

  alias Scheduling.Queue

  @interval_ms :timer.minutes(1)

  @doc "Child spec for the promoter, or `nil` when it is switched off."
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(enabled?(), do: __MODULE__)

  @doc "Whether the promoter should run. On unless configured otherwise."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:scheduling, Scheduling.Queue, [])
    |> Keyword.get(:promoter_enabled, true)
  end

  @doc "How long between passes. Configurable so a test can drive one."
  @spec interval_ms() :: pos_integer()
  def interval_ms do
    Application.get_env(:scheduling, Scheduling.Queue, [])
    |> Keyword.get(:promoter_interval_ms, @interval_ms)
  end

  @doc """
  Promotes anything due right now instead of waiting for the next pass.

  For the moment an entry is created whose time has already passed — a booking
  made late, or a clock difference — so it does not sit invisible for up to a
  minute.
  """
  @spec nudge() :: :ok
  def nudge do
    send(__MODULE__, :promote)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts), do: {:ok, schedule(%{timer: nil}), {:continue, :promote}}

  @impl GenServer
  def handle_continue(:promote, state) do
    promote()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:promote, state) do
    promote()
    {:noreply, schedule(state)}
  end

  defp promote do
    case Queue.promote_due_entries() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Promoted #{count} scheduled entry(ies) to waiting")

      {:error, reason} ->
        Logger.error("Promoting scheduled entries failed: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.error("Promoting scheduled entries crashed: #{Exception.message(error)}")
      :error
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer, info: false)
    %{state | timer: Process.send_after(self(), :promote, interval_ms())}
  end
end
