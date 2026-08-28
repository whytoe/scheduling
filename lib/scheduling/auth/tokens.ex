defmodule Scheduling.Auth.Tokens do
  @moduledoc """
  Validation of OIDC tokens.

  Integrators authenticate to `/api/v1` with an OAuth access token from the
  same realm as the UI, obtained via the client-credentials grant:

      curl -s -X POST "$KEYCLOAK_ISSUER/protocol/openid-connect/token" \\
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

  @role_claims ["realm_access", "resource_access"]

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
    if Enum.any?(@role_claims, &Map.has_key?(id_claims, &1)) do
      id_claims
    else
      case validate_claims(access_token) do
        {:ok, access_claims} -> Map.merge(id_claims, Map.take(access_claims, @role_claims))
        {:error, _reason} -> id_claims
      end
    end
  end

  defp merge_role_claims(id_claims, _token), do: id_claims

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
