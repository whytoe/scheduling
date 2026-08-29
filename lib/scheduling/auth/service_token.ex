defmodule Scheduling.Auth.ServiceToken do
  @moduledoc """
  Holds scheduling's own client-credentials access token for calling ac-core.

  Every outbound core request needs a bearer token. Fetching one per request
  would put an IdP round-trip in front of every call, so this caches the token
  and refreshes it shortly before it expires.

  `Oidcc.client_credentials_token/4` performs the exchange, reusing the
  discovery/JWKS worker `Scheduling.Auth.Provider` already runs — there is no
  hand-rolled token request here.

  ## Why a GenServer rather than an ETS cache

  Serialising through one process means a burst of callers arriving on a cold
  or expired cache produces **one** token request, not one per caller. The
  refresh is not a hot path, so the extra hop costs nothing that matters.

  ## Expiry

  OAuth returns `expires_in` — seconds of validity, not a timestamp — so the
  absolute deadline is computed at fetch time. A token is treated as spent
  `#{60}s before` it actually expires, so one is never handed out that could
  die in flight on a slow request.

  If the provider omits `expires_in` (`:undefined`), we cannot know the
  lifetime, so the token is cached for only a short defensive window rather
  than indefinitely.

  ## Failure

  A failed exchange is never cached — `fetch/0` returns `{:error, reason}`, any
  previously valid token is left untouched, and the next call retries. A caller
  gets an error tuple rather than an exception; ac-core being down must not
  take a LiveView with it.
  """

  use GenServer

  require Logger

  alias Scheduling.Auth
  alias Scheduling.Core

  # Never serve a token inside this window of its expiry.
  @margin_s 60

  # Used when the provider omits expires_in. Short, because the alternative to
  # guessing is re-fetching per call.
  @unknown_expiry_ttl_s 60

  @typedoc "Cached token plus the absolute unix second at which it stops being served."
  @type state :: %{token: String.t() | nil, serve_until: integer() | nil}

  @doc "Child spec for the token holder, or `nil` when core access is unconfigured."
  @spec child_spec_if_enabled() :: module() | nil
  def child_spec_if_enabled, do: if(Core.enabled?(), do: __MODULE__)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns a currently-valid access token, fetching one if the cache is empty or
  close to expiry.

  Returns `{:error, :not_configured}` when core access is off — including when
  the process is absent from the supervision tree, which is the normal state
  for a local checkout.
  """
  @spec fetch(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def fetch(server \\ __MODULE__) do
    if Core.enabled?() do
      call(server)
    else
      {:error, :not_configured}
    end
  end

  @doc """
  Drops the cached token so the next `fetch/0` gets a fresh one.

  For the case where core rejects a token we still believe is valid — a
  revocation, or a key rotation on their side.
  """
  @spec invalidate(GenServer.server()) :: :ok
  def invalidate(server \\ __MODULE__) do
    GenServer.cast(server, :invalidate)
  catch
    :exit, _ -> :ok
  end

  # Enabled but not started — a misconfiguration rather than a crash, so say so
  # instead of letting a noproc exit escape into a request.
  defp call(server) do
    GenServer.call(server, :fetch, 15_000)
  catch
    :exit, {:noproc, _} -> {:error, :not_started}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{token: nil, serve_until: nil}}

  @impl GenServer
  def handle_call(:fetch, _from, state) do
    if servable?(state) do
      {:reply, {:ok, state.token}, state}
    else
      case request_token() do
        {:ok, token, serve_until} ->
          {:reply, {:ok, token}, %{token: token, serve_until: serve_until}}

        {:error, reason} ->
          # Leave the old token in place. It may still be usable, and a failed
          # refresh should not turn a working cache into an outage.
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl GenServer
  def handle_cast(:invalidate, _state), do: {:noreply, %{token: nil, serve_until: nil}}

  defp servable?(%{token: token, serve_until: until})
       when is_binary(token) and is_integer(until),
       do: now() < until

  defp servable?(_state), do: false

  defp request_token do
    case exchange() do
      {:ok, %Oidcc.Token{access: %Oidcc.Token.Access{token: token, expires: expires}}} ->
        {:ok, token, serve_until(expires)}

      {:ok, other} ->
        Logger.error("Core token response carried no access token: #{inspect(other)}")
        {:error, :no_access_token}

      {:error, reason} ->
        Logger.error("Could not obtain a core API token: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The exchange reaches the shared provider worker with a GenServer.call, so
  # it *exits* — rather than returning an error — when that worker is down or
  # still backing off after a failed discovery. Unhandled, that would take this
  # holder down with it and turn an IdP blip into a supervision cascade.
  defp exchange do
    Oidcc.client_credentials_token(
      Auth.provider_name(),
      Core.client_id(),
      Core.client_secret(),
      %{scope: Core.scopes()}
    )
  catch
    :exit, reason -> {:error, {:provider_unavailable, reason}}
  end

  # `expires` is expires_in (seconds of validity), so the deadline is relative
  # to now. Subtracting the margin can go negative for a very short-lived
  # token; that just means it is never servable from cache, which is correct.
  defp serve_until(expires) when is_integer(expires) and expires > 0,
    do: now() + expires - @margin_s

  defp serve_until(_undefined), do: now() + @unknown_expiry_ttl_s

  defp now, do: System.system_time(:second)
end
