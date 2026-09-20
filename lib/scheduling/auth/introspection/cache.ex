defmodule Scheduling.Auth.Introspection.Cache do
  @moduledoc """
  Remembers a live introspection answer for a short, bounded window.

  ac-core issues opaque access tokens, so every `/api/v1` bearer token takes the
  introspection path — and introspection against ac-core was measured at **1.3
  to 1.7 seconds per call** once we began authenticating properly. At that cost
  an API with real traffic is not slow, it is unusable.

  ## Why this has a TTL rather than following `exp`

  Caching to the token's own expiry is the obvious implementation and the wrong
  one. It reproduces JWT semantics exactly — including the revocation hole
  introspection exists to close — while still paying the round-trip on every
  miss. The worst of both.

  A short window keeps most of what introspection is for. A token revoked at
  ac-core stops working here within `ttl_seconds/0` rather than immediately,
  and that number is small, stated, and in `docs/auth.md` beside the rest of
  the revocation discussion. "Revocation takes effect within a minute" is a
  sentence an operator can act on. "Revocation takes effect whenever the token
  would have expired anyway" is not.

  The expiry is `min(now + ttl, exp)`, so a token about to expire is never held
  past its own deadline.

  ## Positive answers only

  A refusal is never cached. Caching one would extend an outage: a momentary
  provider error would pin a legitimate caller out for the rest of the window,
  and the caller could do nothing about it. Re-asking on a failure is cheap
  precisely because failures are rare.

  ## The key is a digest, never the token

  Entries are keyed on a SHA-256 of the bearer token. A cache keyed on the
  token itself is a table of live credentials — readable by anything that can
  reach the node, and dumped wholesale by any crash report that inspects it.
  The digest is enough to recognise the same token again and useless to anyone
  who obtains it.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @default_ttl_seconds 45
  @sweep_interval_ms :timer.minutes(1)

  @doc "Child spec for the cache, or `nil` when it is switched off."
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(enabled?(), do: __MODULE__)

  @doc """
  Whether answers are cached at all.

  On by default. `OIDC_INTROSPECTION_CACHE=false` turns it off for a deployment
  that would rather pay the round-trip than accept any revocation window.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: config(:introspection_cache, true)

  @doc """
  How long a live answer is honoured.

  The revocation window. Deliberately short and deliberately stated — see the
  moduledoc.
  """
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: config(:introspection_cache_ttl_seconds, @default_ttl_seconds)

  @doc """
  Returns the claims cached for `token`, or `:miss`.

  Reads straight from ETS rather than through the GenServer: this is on the
  path of every authenticated API request, and serialising it through one
  process would replace an IdP round-trip with a mailbox.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :miss
  def fetch(token) when is_binary(token) do
    case :ets.lookup(@table, digest(token)) do
      [{_digest, claims, expires_at}] ->
        if expires_at > now(), do: {:ok, claims}, else: :miss

      [] ->
        :miss
    end
  rescue
    # The table is absent when the cache is switched off, or during shutdown.
    # A miss is always a safe answer — it costs a round-trip and nothing else.
    ArgumentError -> :miss
  end

  @doc """
  Caches a live answer.

  `claims["exp"]` caps the window: a token about to expire is never held past
  its own deadline.
  """
  @spec put(String.t(), map()) :: :ok
  def put(token, claims) when is_binary(token) and is_map(claims) do
    :ets.insert(@table, {digest(token), claims, expires_at(claims)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops everything. For tests, and for an operator who needs the window gone now."
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
    # Public so `fetch/1` can read without a message, and `write_concurrency`
    # because writes happen on the same hot path as reads.
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
    # Expired rows are already ignored by fetch/1, so this is only about not
    # holding claims — and the memory they occupy — longer than the window
    # says. Hygiene, not correctness.
    deleted = :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
    if deleted > 0, do: Logger.debug("Swept #{deleted} expired introspection answer(s)")

    {:noreply, schedule(state)}
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer, info: false)
    %{state | timer: Process.send_after(self(), :sweep, @sweep_interval_ms)}
  end

  defp expires_at(claims) do
    ttl_deadline = now() + ttl_seconds()

    case claims["exp"] do
      exp when is_integer(exp) -> min(ttl_deadline, exp)
      _absent -> ttl_deadline
    end
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  defp now, do: System.system_time(:second)

  defp config(key, default) do
    Application.get_env(:scheduling, Scheduling.Auth, []) |> Keyword.get(key, default)
  end
end
