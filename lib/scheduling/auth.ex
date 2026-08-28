defmodule Scheduling.Auth do
  @moduledoc """
  OpenID Connect configuration for the Keycloak (or any OIDC-compliant)
  identity provider.

  Two surfaces authenticate against the same realm:

    * **Browser SSO** — operators sign in to the LiveView UI via the
      authorization-code flow with PKCE. See `SchedulingWeb.AuthController`.
    * **API bearer tokens** — integrators (the intake-form bridge, the
      check-in / queueing app) call `/api/v1` with an access token obtained
      via the client-credentials grant. See `SchedulingWeb.Plugs.ApiAuth`.

  Both paths validate against the provider's JWKS, which
  `Oidcc.ProviderConfiguration.Worker` discovers from the issuer's
  `.well-known/openid-configuration` and refreshes on key rotation.

  ## Enabling

  Auth is **enabled when `:issuer`, `:client_id` and `:client_secret` are all
  configured** and disabled otherwise. This mirrors `Scheduling.Compliance`:
  an unconfigured local dev environment keeps working without an IdP.

  Unlike the compliance gate, though, disabled auth fails *open* — every route
  and endpoint is public. So `config/runtime.exs` **refuses to boot a `:prod`
  release** with auth unconfigured unless `AUTH_DISABLED=true` is set
  explicitly, which logs a loud warning at startup.

  ## Roles

  Roles come from the token's claims — there is no local users table. Keycloak
  publishes them in two places and we take the union:

      realm_access.roles                      # realm roles
      resource_access.<client_id>.roles       # client roles for this client

  Four roles are recognised (see `Scheduling.Auth.Identity`):

  | Role       | Grants                                                          |
  |------------|-----------------------------------------------------------------|
  | `admin`    | Everything, including catalog CRUD and webhook subscriptions.   |
  | `operator` | Board / queue actions (accept, complete, requeue, acknowledge). |
  | `viewer`   | Read-only access to every screen and `GET` endpoint.            |
  | `service`  | Machine-to-machine integration access to `/api/v1`.             |

  Any other role string on the token is carried through untouched but grants
  nothing.
  """

  @provider_name Scheduling.Auth.Provider

  @doc """
  Name of the `Oidcc.ProviderConfiguration.Worker` process. Used as the
  registered name so plugs and controllers can look the provider up without
  threading a pid around.
  """
  @spec provider_name() :: GenServer.name()
  def provider_name, do: @provider_name

  @doc """
  True when the identity provider is fully configured. Every auth plug and
  hook short-circuits to "allow" when this is false.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    not (is_nil(issuer()) or is_nil(client_id()) or is_nil(client_secret()))
  end

  @doc "Issuer URL, e.g. `https://sso.example.org/realms/clinic`."
  @spec issuer() :: String.t() | nil
  def issuer, do: get(:issuer)

  @doc "OAuth client id for this application."
  @spec client_id() :: String.t() | nil
  def client_id, do: get(:client_id)

  @doc "OAuth client secret for this application."
  @spec client_secret() :: String.t() | nil
  def client_secret, do: get(:client_secret)

  @doc """
  Audience values accepted on API access tokens, beyond the client id itself.

  Keycloak only puts a client in an access token's `aud` when that client has
  an audience mapper, so a token minted for the bridge may carry
  `aud: "scheduling-api"` rather than this app's client id. List those values
  here (`KEYCLOAK_API_AUDIENCES`, comma-separated).
  """
  @spec trusted_audiences() :: [String.t()]
  def trusted_audiences do
    configured = get(:trusted_audiences) || []
    Enum.uniq(Enum.reject([client_id() | configured], &is_nil/1))
  end

  @doc """
  Signing algorithms accepted on API access tokens.

  Access tokens are not ID tokens, so the OIDC discovery document does not
  say how they are signed — RFC 9068 leaves it to the deployment. We pin the
  list rather than accepting whatever the token header claims, which is what
  makes `alg: none` and algorithm-confusion attacks a non-issue.
  """
  @spec signing_algs() :: [String.t()]
  def signing_algs, do: get(:signing_algs) || ["RS256"]

  @doc "Scopes requested during the browser authorization-code flow."
  @spec scopes() :: [String.t()]
  def scopes, do: get(:scopes) || ["openid", "profile", "email", "roles"]

  @doc """
  How long a browser session is trusted before the user is bounced back
  through the IdP, in seconds. Capped by the ID token's own `exp`.
  """
  @spec session_ttl_seconds() :: pos_integer()
  def session_ttl_seconds, do: get(:session_ttl_seconds) || 8 * 60 * 60

  defp get(key), do: Application.get_env(:scheduling, __MODULE__, [])[key]
end
