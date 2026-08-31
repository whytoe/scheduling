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

  ## Tenancy

  The provider is multi-tenant; a deployment of this app serves exactly one
  tenant. ac-core nests **organization → practice → location** and scopes every
  `/v1` read to the caller's practice, so the practice is the level that
  matches how the data is partitioned.

  When `expected_tenancy_id/0` is set, a token whose id does not match is
  refused on both surfaces regardless of its roles — see
  `tenancy_permitted?/1`. Which claim carries that id is configurable
  (`tenancy_claim/0`), because ac-core does not advertise a practice claim by
  name and the mapping is still unconfirmed.

  This is an **authentication** boundary, not a data one: it keeps other
  tenants out, but no query filters by tenant.
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

  @doc """
  Whether the *environment* supplies all three OIDC settings.

  This exists for one caller: the `:prod` boot guard in `config/runtime.exs`.

  It must read `System.get_env/1` and **must never read the application
  environment**, because it is called from inside `runtime.exs` while that file
  is still assembling the very config `enabled?/0` reads. A config file
  accumulates a keyword list that is applied only once evaluation finishes, so
  `Application.get_env/3` during evaluation sees the build-time value — for
  this key, nothing. Wiring the guard to `enabled?/0` made it raise on every
  `:prod` boot no matter how the release was configured, which is not the sort
  of thing the test suite catches: `:test` applies its config normally long
  before anything starts.

  Blank is treated as absent. A provider will not accept an empty client
  secret, and refusing at boot beats a confusing failure at the token
  exchange.
  """
  @spec configured_from_env?() :: boolean()
  def configured_from_env? do
    Enum.all?(["OIDC_ISSUER", "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET"], fn var ->
      case System.get_env(var) do
        value when is_binary(value) -> String.trim(value) != ""
        nil -> false
      end
    end)
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
  Claim naming the identity's organisation. Display only — the enforced value
  is the id from `org_id_claim/0`, since names change and ids do not.
  """
  @spec org_claim() :: String.t()
  def org_claim, do: get(:org_claim) || "astrum_org"

  @doc "Claim naming the organisation's stable id."
  @spec org_id_claim() :: String.t()
  def org_id_claim, do: get(:org_id_claim) || "astrum_org_id"

  @doc """
  Which claim carries the id this deployment is scoped to.

  ac-core nests **organization → practice → location**, and every `/v1` read is
  "scoped to the caller's practice[s]" — so a *practice* is the unit that
  matches how the data is actually partitioned, and a scheduling deployment
  serves one.

  Which claim carries the practice id is **not yet confirmed**: ac-core's
  `claims_supported` advertises `astrum_org`, `astrum_org_id`, `astrum_tenant`
  and `astrum_location`, but nothing named for a practice. So this is
  configurable — `OIDC_TENANCY_CLAIM` — and defaults to `astrum_org_id`, the
  one we have actually seen. Point it at whichever claim turns out to carry the
  practice and the check moves down a level without a code change.
  """
  @spec tenancy_claim() :: String.t()
  def tenancy_claim, do: get(:tenancy_claim) || "astrum_org_id"

  @doc """
  The single tenant this deployment serves, as the id expected in
  `tenancy_claim/0`.

  `nil` (the default) disables the check, matching how the rest of this module
  behaves when unconfigured. Set `SCHEDULING_TENANCY_ID` to turn it on.
  """
  @spec expected_tenancy_id() :: String.t() | nil
  def expected_tenancy_id, do: get(:expected_tenancy_id)

  @doc """
  True when an identity's tenancy id is the one this deployment serves.

  The provider is multi-tenant; a scheduling deployment is not. A token from
  another tenant is refused on both surfaces even when its roles would
  otherwise permit the call — otherwise a valid operator at one clinic could
  read another clinic's board.

  A token with **no** tenancy id is refused too when one is expected. That case
  is either a claim-mapping mistake or a token from somewhere that does not
  carry tenancy at all, and neither is something to wave through. Note the
  failure mode: if `tenancy_claim/0` names a claim the provider does not send,
  *everyone* is refused rather than only outsiders.

  Takes the id rather than the `Scheduling.Auth.Identity` struct to keep this
  module free of a compile-time dependency on `Identity`, which already
  depends on it. Both `SchedulingWeb.Plugs.ApiAuth` and
  `SchedulingWeb.AuthController` call this, so the two surfaces cannot drift
  apart on what "permitted here" means.
  """
  @spec tenancy_permitted?(String.t() | nil) :: boolean()
  def tenancy_permitted?(tenancy_id) do
    case expected_tenancy_id() do
      nil -> true
      expected -> tenancy_id == expected
    end
  end

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
