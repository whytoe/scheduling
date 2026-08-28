defmodule Scheduling.Auth do
  @moduledoc """
  OpenID Connect configuration for the deployment's identity provider.

  Provider-neutral: everything here goes through OIDC discovery and the
  provider's JWKS. The only place a provider's individuality shows through is
  *where it puts roles and tenancy in the token*, and that is configuration
  (`role_claims/0`, `org_claim/0`, `tenant_claim/0`) rather than code.

  Two surfaces authenticate against the same issuer:

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

  Roles come from the token's claims — there is no local users table. OIDC
  does not standardise where they live, so `role_claims/0` holds a list of
  dotted claim paths and every one present on the token is unioned. The
  default covers the shapes we have met:

      astrum_roles                        # Astrum core-api
      roles                               # the plain case
      realm_access.roles                  # Keycloak realm roles
      resource_access.<client_id>.roles   # Keycloak client roles

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

  A provider does not necessarily put *us* in the `aud` of a token minted for
  another client — Keycloak needs an explicit audience mapper, and other
  providers vary — so a token from the check-in bridge may carry
  `aud: "scheduling-api"` rather than this app's client id. List those values
  here (`OIDC_API_AUDIENCES`, comma-separated).
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
  Dotted claim paths searched for roles, unioned. `<client_id>` in a path is
  substituted with `client_id/0`. Override with `OIDC_ROLE_CLAIMS`.
  """
  @spec role_claims() :: [String.t()]
  def role_claims do
    get(:role_claims) ||
      ["astrum_roles", "roles", "realm_access.roles", "resource_access.<client_id>.roles"]
  end

  @doc """
  Claim naming the identity's organisation. Captured on the identity but not
  yet enforced — see `docs/auth.md` §"What is not covered".
  """
  @spec org_claim() :: String.t()
  def org_claim, do: get(:org_claim) || "astrum_org"

  @doc "Claim naming the organisation's stable id."
  @spec org_id_claim() :: String.t()
  def org_id_claim, do: get(:org_id_claim) || "astrum_org_id"

  @doc "Claim naming the tenant this identity belongs to."
  @spec tenant_claim() :: String.t()
  def tenant_claim, do: get(:tenant_claim) || "astrum_tenant"

  @doc """
  Values merged over the provider's discovery document before `oidcc` validates
  it, for filling in fields a provider omits.

  `oidcc` enforces the fields OIDC Discovery 1.0 §3 marks REQUIRED and refuses
  to start without them. Astrum core-api omits `subject_types_supported`, so
  without this the provider worker crash-loops at boot and every request
  returns `503 provider_unavailable`.

  The default supplies that one field as `["public"]`. Nothing in this app
  reads it — it describes whether the provider issues pairwise `sub` values,
  which only matters to a client correlating subjects across relying parties —
  so filling it in is inert beyond satisfying the validation.

  **This is a workaround for a non-conformant document, not a feature.** The
  right fix is for the provider to publish the field; drop the override
  (`OIDC_DISCOVERY_OVERRIDES={}`) once it does.
  """
  @spec discovery_overrides() :: map()
  def discovery_overrides do
    get(:discovery_overrides) || %{"subject_types_supported" => ["public"]}
  end

  @doc """
  How long a browser session is trusted before the user is bounced back
  through the IdP, in seconds. Capped by the ID token's own `exp`.
  """
  @spec session_ttl_seconds() :: pos_integer()
  def session_ttl_seconds, do: get(:session_ttl_seconds) || 8 * 60 * 60

  defp get(key), do: Application.get_env(:scheduling, __MODULE__, [])[key]
end
