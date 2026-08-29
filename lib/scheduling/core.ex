defmodule Scheduling.Core do
  @moduledoc """
  Configuration for the Avenue D Core API (ac-core) — the platform's system of
  record for patients, providers, practices and locations.

  Scheduling talks to it as an **OAuth client**: `Scheduling.Auth.ServiceToken`
  obtains a client-credentials access token, and `Scheduling.Core.Client` uses
  that token to call the `/v1/*` endpoints.

  Note this is a *different* OAuth client from the one browser SSO uses
  (`Scheduling.Auth`). That one identifies the web app to end users; this one
  identifies scheduling-as-a-service to ac-core, and holds only the read scopes
  the sync needs. Separate credentials means the browser client's secret is not
  also a key to the patient registry.

  Both point at the same issuer, so the discovery/JWKS worker
  (`Scheduling.Auth.Provider`) is shared — which is why `enabled?/0` requires
  `Scheduling.Auth.enabled?/0` as well as its own credentials.

  | Config key        | Env var              | Default |
  |-------------------|----------------------|---------|
  | `base_url`        | `CORE_API_URL`       | —       |
  | `client_id`       | `CORE_CLIENT_ID`     | —       |
  | `client_secret`   | `CORE_CLIENT_SECRET` | —       |
  | `scopes`          | `CORE_SCOPES`        | `core:patients:read core:organizations:read` |
  | `http_timeout_ms` | —                    | `5000`  |

  There is deliberately **no default `base_url`**. A wrong host is worse than
  an unconfigured one: it would send a bearer token somewhere unintended.
  """

  @default_scopes ["core:patients:read", "core:organizations:read"]

  @doc """
  True when everything needed to call ac-core is present.

  Requires `Scheduling.Auth.enabled?/0` too: the token exchange runs through
  the shared provider worker, which does not exist without an issuer.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Scheduling.Auth.enabled?() and
      not (is_nil(base_url()) or is_nil(client_id()) or is_nil(client_secret()))
  end

  @doc "Base URL of the core API, e.g. `https://ac-core.example`. Paths are `/v1/...`."
  @spec base_url() :: String.t() | nil
  def base_url, do: get(:base_url)

  @doc "OAuth client id scheduling presents to ac-core."
  @spec client_id() :: String.t() | nil
  def client_id, do: get(:client_id)

  @doc "That client's secret."
  @spec client_secret() :: String.t() | nil
  def client_secret, do: get(:client_secret)

  @doc """
  Scopes requested on the client-credentials token.

  Read-only by default. `core:patients:write` is deliberately absent —
  scheduling projects patient data, it does not author it.
  """
  @spec scopes() :: [String.t()]
  def scopes, do: get(:scopes) || @default_scopes

  @doc "Request timeout for core API calls."
  @spec http_timeout_ms() :: pos_integer()
  def http_timeout_ms, do: get(:http_timeout_ms) || 5_000

  defp get(key), do: Application.get_env(:scheduling, __MODULE__, [])[key]
end
