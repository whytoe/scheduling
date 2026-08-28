defmodule Scheduling.Auth.SessionRevocation.Sweeper do
  @moduledoc """
  Periodically drops expired rows from `revoked_sessions`.

  Pure hygiene. A revocation row is worthless once the session it names would
  have lapsed anyway, and `Scheduling.Auth.SessionRevocation` explains why
  removing one cannot resurrect a session. Without this the table would grow
  by one row per logout forever.

  Hourly, because the rows it removes are already inert — the only cost of
  sweeping late is a few kilobytes. Absent entirely when auth is unconfigured,
  matching `Scheduling.Auth.Provider`.
  """

  use GenServer

  require Logger

  alias Scheduling.Auth
  alias Scheduling.Auth.SessionRevocation

  @interval_ms :timer.hours(1)

  @doc "Child spec for the sweeper, or `nil` when auth is disabled."
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(Auth.enabled?(), do: __MODULE__)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    # Nothing to sweep at boot that cannot wait; skipping the immediate pass
    # keeps startup off the database.
    {:ok, schedule(%{})}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    case SessionRevocation.sweep() do
      0 -> :ok
      n -> Logger.debug("Swept #{n} expired session revocation(s)")
    end

    {:noreply, schedule(state)}
  end

  defp schedule(state) do
    Process.send_after(self(), :sweep, @interval_ms)
    state
  end
end
