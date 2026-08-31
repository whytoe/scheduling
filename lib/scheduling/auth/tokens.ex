defmodule Scheduling.Auth.Tokens do
  @moduledoc """
  Validation of OIDC tokens.

  Integrators authenticate to `/api/v1` with an OAuth access token from the
  same realm as the UI, obtained via the client-credentials grant:

      curl -s -X POST "$OIDC_ISSUER/oauth/token" \\
        -d grant_type=client_credentials \\
        -d client_id=intake-bridge -d client_secret=...

  An access token is *not* an ID token: OIDC does not specify its shape, so
  the discovery document does not say how it is signed. That is why
  `Scheduling.Auth.signing_algs/0` pins the accepted algorithms here rather
  than trusting the token header's `alg` — pinning is what makes `alg: none`
  and RS256/HS256 confusion inapplicable.

  `Oidcc.Token.validate_jwt/3` checks, against the provider's live JWKS:
  signature, `iss`, `aud` (against `Scheduling.Auth.trusted_audiences/0`),
  `exp` and `nbf`. On an unrecognised `kid` it asks the provider worker to
  re-fetch the JWKS once before failing, so a key rotation does not reject
  valid traffic.
  """

  require Logger

  alias Scheduling.Auth
  alias Scheduling.Auth.Identity
  alias Scheduling.Auth.Provider

  @typedoc """
  `:invalid_token` collapses every validation failure — bad signature, wrong
  issuer, wrong audience, malformed JWT. The distinctions matter to us in the
  log, never to the caller: telling an unauthenticated client *which* check
  failed is free oracle access.
  """
  @type error :: :invalid_token | :token_expired | :provider_unavailable

  @backchannel_logout_event "http://schemas.openid.net/event/backchannel-logout"

  @doc """
  Validates a raw bearer token and returns the identity it names.

  Callers must have already confirmed `Scheduling.Auth.enabled?/0`.
  """
  @spec validate(String.t()) :: {:ok, Identity.t()} | {:error, error()}
  def validate(token) when is_binary(token) do
    with {:ok, claims} <- validate_claims(token) do
      {:ok, Identity.from_claims(claims, Auth.client_id())}
    end
  end

  @doc """
  Builds the identity for a completed browser login.

  The profile (`sub`, `email`, `name`) comes from the ID token, which
  `Oidcc.retrieve_token/5` has already validated against the nonce and the
  provider's keys.

  Roles are the wrinkle. Keycloak puts `realm_access` / `resource_access` on
  the **access token** by default; the equivalent "Add to ID token" toggles on
  its role mappers are off out of the box. Reading roles from the ID token
  alone would therefore leave every operator role-less on a stock realm. So
  when the ID token carries no role claims we validate the access token —
  the same checks an API bearer token gets, no shortcut — and take the role
  claims from there.

  If the access token is opaque rather than a JWT (legal for a non-Keycloak
  provider), validation fails and we fall back to whatever the ID token says.
  Sign-in still succeeds; the user simply has the roles the ID token granted.
  """
  @spec identity_from_login(Oidcc.Token.t()) :: Identity.t()
  def identity_from_login(%Oidcc.Token{id: %Oidcc.Token.Id{claims: id_claims}} = token) do
    id_claims
    |> merge_role_claims(token)
    |> Identity.from_claims(Auth.client_id())
  end

  defp merge_role_claims(id_claims, %Oidcc.Token{access: %Oidcc.Token.Access{token: access_token}}) do
    claims = role_claim_roots()

    if Enum.any?(claims, &Map.has_key?(id_claims, &1)) do
      id_claims
    else
      case validate_claims(access_token) do
        {:ok, access_claims} -> Map.merge(id_claims, Map.take(access_claims, claims))
        {:error, _reason} -> id_claims
      end
    end
  end

  defp merge_role_claims(id_claims, _token), do: id_claims

  # The top-level key of each configured role claim, since that is the depth a
  # claims map is keyed at: `realm_access.roles` lives under `realm_access`.
  #
  # Derived from `Auth.role_claims/0` rather than hardcoded. It used to be a
  # fixed `["realm_access", "resource_access"]` — the two Keycloak shapes — so
  # against a provider that puts roles anywhere else (ac-core uses
  # `astrum_roles`) the check above never matched, and *every* sign-in fell
  # through to validating the access token it did not need. That logged a
  # "Rejected bearer token" line on each successful login and asked for a JWKS
  # refresh to go with it. Roles still resolved, because `Identity.from_claims/2`
  # reads the configured list; the fallback was pure waste, and the false
  # rejection made real bearer-token failures impossible to spot in the log.
  defp role_claim_roots do
    Auth.role_claims()
    |> Enum.map(&(&1 |> String.split(".", parts: 2) |> hd()))
    |> Enum.uniq()
  end

  @doc """
  Validates a back-channel logout token and returns what it says to end.

  Runs the same signature / issuer / audience / expiry checks an API bearer
  token gets — a logout token is attacker-reachable (the endpoint is public and
  unauthenticated), so it is exactly as security-critical as a login. Then the
  checks specific to OpenID Connect Back-Channel Logout 1.0 §2.6:

    * an `events` claim containing the back-channel-logout member,
      which is what distinguishes a logout token from a replayed ID token
    * a `sub`, a `sid`, or both — otherwise it names nothing
    * **no** `nonce`, which only ever belongs on an ID token

  Returns `{:ok, %{sub: sub, sid: sid}}`; `sid` may be nil.

  ## Known constraint: sid-only tokens are rejected

  §2.4 permits a logout token to carry `sid` *instead of* `sub`. `oidcc` does
  not: `oidcc_token:verify_missing_required_claims/1` requires
  `iss`/`sub`/`aud`/`exp`/`iat` on every JWT it validates, so a sid-only token
  fails before reaching the checks here — logged as
  `{missing_claim, "sub", ...}`.

  We accept that. Validating a sid-only token would mean composing
  `oidcc_jwt_util` primitives and hand-writing the `aud`/`exp`/`nbf`
  comparisons, and this endpoint is public and unauthenticated — a bespoke
  validator here is exactly the wrong place to save a round trip. Providers
  that send `sub` (ac-core sends `sub` on every other token type) are
  unaffected.

  **If back-channel logout ever silently stops working, look here first**: a
  provider that switched to sid-only tokens would produce 400s and a
  `missing_claim` log line, not a partial success.

  Replay is not separately guarded: `Scheduling.Auth.SessionRevocation.revoke/2`
  upserts, so re-delivering a logout token re-revokes an already-revoked
  session and changes nothing.
  """
  @spec validate_logout_token(String.t()) ::
          {:ok, %{sub: String.t() | nil, sid: String.t() | nil}}
          | {:error, error() | :invalid_logout_token}
  def validate_logout_token(token) when is_binary(token) do
    with {:ok, claims} <- validate_claims(token) do
      sub = presence(claims["sub"])
      sid = presence(claims["sid"])

      cond do
        not logout_event?(claims["events"]) ->
          reject("missing the back-channel-logout events claim")

        # Unreachable in practice — oidcc requires `sub` and rejects first.
        # Kept so the guarantee is stated in code, not only in the doc.
        is_nil(sub) and is_nil(sid) ->
          reject("carries neither sub nor sid")

        not is_nil(presence(claims["nonce"])) ->
          reject("carries a nonce, which belongs only on an ID token")

        true ->
          {:ok, %{sub: sub, sid: sid}}
      end
    end
  end

  defp logout_event?(events) when is_map(events),
    do: Map.has_key?(events, @backchannel_logout_event)

  defp logout_event?(_events), do: false

  defp reject(why) do
    Logger.warning("Rejected back-channel logout token: #{why}")
    {:error, :invalid_logout_token}
  end

  # oidcc decodes JSON null to the atom :null, not nil — see
  # `Scheduling.Auth.Identity`, which normalises the same way.
  defp presence(value) when value in [nil, :null, ""], do: nil
  defp presence(value), do: value

  defp validate_claims(token) do
    with {:ok, client_context} <- client_context() do
      opts = %{
        signing_algs: Auth.signing_algs(),
        trusted_audiences: Auth.trusted_audiences(),
        refresh_jwks: :oidcc_jwt_util.refresh_jwks_fun(Auth.provider_name())
      }

      case Oidcc.Token.validate_jwt(token, client_context, opts) do
        {:ok, claims} ->
          {:ok, claims}

        {:error, :token_expired} ->
          {:error, :token_expired}

        {:error, reason} ->
          Logger.info("Rejected bearer token: #{inspect(reason)}")
          {:error, :invalid_token}
      end
    end
  end

  defp client_context do
    case Provider.client_context() do
      {:ok, context} ->
        {:ok, context}

      {:error, reason} ->
        # Discovery hasn't completed or the IdP is unreachable. This is our
        # outage, not the caller's bad request — 503, not 401.
        Logger.error("OIDC provider unavailable: #{inspect(reason)}")
        {:error, :provider_unavailable}
    end
  end
end
