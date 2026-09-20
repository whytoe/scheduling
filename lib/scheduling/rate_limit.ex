defmodule Scheduling.RateLimit do
  @moduledoc """
  A fixed-window request counter, keyed per caller.

  ## What it is actually protecting

  Two things, and the second is the urgent one.

  The first is the case this was filed for: a clinic opening produces a burst
  of sign-ins, and a bridge with a retry loop can produce an unbounded one. A
  per-caller quota keeps one integrator's bad afternoon off everybody else's.

  The second only became true recently. ac-core issues opaque access tokens, so
  a bearer token that fails JWT validation goes to `/oauth/introspect` — a call
  measured at **1.3 to 1.7 seconds**. A refusal is deliberately never cached,
  because caching one would extend an outage. So an attacker with a single
  invalid token can hold a request open for well over a second, repeatedly, at
  no cost to themselves. That is cheap amplification, and it exists on the
  *unauthenticated* path where a quota is normally hardest to apply.

  ## The key is the bearer token's digest

  Not the IP. `conn.remote_ip` here is the ingress controller — there is no
  `RemoteIp` plug and no decision yet about trusting `X-Forwarded-For` — so
  every caller in the world shares one address and an IP quota would either
  limit nobody or lock out everybody.

  The token digest works for both cases above. It identifies a service for
  quota purposes exactly as well as its subject claim would, and unlike the
  subject it is available **before** authentication, which is the only place a
  limit can defend the expensive path.

  A request carrying no token is not counted, and does not need to be: it is
  refused by `SchedulingWeb.Plugs.ApiAuth` immediately, without an introspection
  round-trip. Cheap requests do not need a quota.

  As everywhere else, the digest and not the token: a table of live credentials
  is not something to keep, and any crash report inspecting this would dump it.

  ## Fixed windows, and what that costs

  A fixed window is not a sliding one. A caller can spend its whole allowance at
  the end of one window and again at the start of the next, so the true
  short-term ceiling is twice `limit/0`. That is a well-known property rather
  than an oversight, and it is acceptable here because the limit exists to stop
  a runaway loop rather than to meter billing. Stated so nobody discovers it in
  a graph and reports it as a bug.

  ## One node

  Counters are in-process. This deployment runs a single pod, so that is
  accurate. **If it is ever scaled to more than one replica, each pod keeps its
  own counter and the effective limit multiplies by the replica count.** That
  is the moment to move this to a shared store, and the reason the number
  deserves re-deriving rather than re-using.
  """

  use GenServer

  @table __MODULE__
  @default_limit 120
  @default_window_seconds 60

  @typedoc "Allowed, or refused with the seconds until the window resets."
  @type verdict :: :ok | {:error, {:rate_limited, pos_integer()}}

  @doc "Child spec for the limiter, or `nil` when it is switched off."
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(enabled?(), do: __MODULE__)

  @doc "Whether requests are counted at all. On by default."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:rate_limit_enabled, true)

  @doc "Requests allowed per window, per caller."
  @spec limit() :: pos_integer()
  def limit, do: config(:rate_limit, @default_limit)

  @doc "How long a window lasts."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: config(:rate_limit_window_seconds, @default_window_seconds)

  @doc """
  Counts one request against `key` and says whether to allow it.

  Increments atomically in ETS rather than through the GenServer: this runs on
  every API request, and a limiter that serialises the thing it is protecting
  has made the problem worse.
  """
  @spec check(binary()) :: verdict()
  def check(key) when is_binary(key) do
    window = div(now(), window_seconds())
    limit = limit()

    count = :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0})

    if count <= limit do
      :ok
    else
      {:error, {:rate_limited, seconds_until_next_window()}}
    end
  rescue
    # No table: the limiter is off, or the node is shutting down. Allowing the
    # request is the right failure direction — a limiter that cannot count must
    # not become an outage of its own.
    ArgumentError -> :ok
  end

  @doc "Digest of a bearer token, for use as a key. Never store the token."
  @spec key_for_token(String.t()) :: binary()
  def key_for_token(token) when is_binary(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc "Drops all counters. For tests, and for lifting a limit immediately."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, schedule(%{timer: nil})}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    # Keys embed their window, so an old window's row is dead the moment the
    # window turns. Without this the table grows by one row per caller per
    # window forever.
    cutoff = div(now(), window_seconds()) - 1

    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])

    {:noreply, schedule(state)}
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer, info: false)
    %{state | timer: Process.send_after(self(), :sweep, window_seconds() * 2 * 1000)}
  end

  defp seconds_until_next_window do
    window = window_seconds()
    max(window - rem(now(), window), 1)
  end

  defp now, do: System.system_time(:second)

  defp config(key, default) do
    Application.get_env(:scheduling, Scheduling.Api, []) |> Keyword.get(key, default)
  end
end
