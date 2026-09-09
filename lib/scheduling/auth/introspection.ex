defmodule Scheduling.Auth.Introspection do
  @moduledoc """
  Validates a bearer token by asking the provider about it (RFC 7662), for
  providers whose access tokens are not JWTs.

  `Scheduling.Auth.Tokens` validates a bearer token against the provider's
  JWKS. That only works if the access token *is* a signed JWT — and OIDC does
  not require it to be. An access token is opaque to the client by
  specification; only the ID token has a defined shape. A provider that issues
  a random string instead will fail every JWKS check, no matter how correct
  the client is.

  ac-core appears to be such a provider. During the first production login its
  **ID token validated and its access token failed with `:no_matching_key`** —
  from the same token response, against the same JWKS, at the same moment.
  Discovery also declares `id_token_signing_alg_values_supported` with no
  equivalent for access tokens, and advertises an `introspection_endpoint`,
  which a provider issuing self-contained JWTs has little use for.

  Without this module the consequence is total: `SchedulingWeb.Plugs.ApiAuth`
  rejects **every** `/api/v1` bearer token, so neither the check-in bridge nor
  the intake bridge can authenticate — while browser SSO keeps working
  perfectly, because that path only needs the ID token. An outage confined to
  the surface nobody is looking at.

  ## Why this is a fallback rather than a replacement

  JWT validation is tried first and this runs only when it fails. Two reasons,
  and neither is politeness to Keycloak:

    * **It is local.** A JWT is verified against keys already in memory. Making
      introspection the primary path would put a round-trip to the IdP in front
      of every API request, and make the IdP a hard dependency of every read.
    * **It stays correct if ac-core changes.** If access tokens become JWTs
      tomorrow, the fast path simply starts succeeding and this stops being
      reached. Nothing needs to be reconfigured, and nothing silently degrades.

  The cost is one extra round-trip on tokens that are genuinely invalid. That
  is the right way round: a rejected token is the rare case, and it is already
  the case we are willing to spend time on.

  ## What is deliberately not here: caching

  Caching introspection results would remove the per-request round-trip, and it
  would also throw away the one thing introspection is uniquely good for.
  A JWT is valid until it expires because nothing can be asked; an
  introspection answer is *current*, so a token revoked at the IdP stops
  working here on the next request. Caching to `exp` reproduces JWT semantics
  exactly, including the revocation hole, while keeping the round-trip on cache
  misses.

  A short bounded TTL is the usual compromise and is worth having — but it is
  a deliberate trade with a number attached, not an implementation detail to
  fold into the change that makes the API work at all. Tracked separately.

  ## Trust, and why `client_self_only` is off

  oidcc defaults `client_self_only: true`, which accepts an introspection
  response only when its `client_id` is *ours*. That is the right default for a
  client checking tokens it was itself issued. It is the wrong one here, and
  turning it off is the whole point rather than a loosening: every token this
  plug will ever see belongs to **somebody else** — the check-in bridge, the
  intake bridge — so `client_self_only` would reject exactly the traffic
  `/api/v1` exists to serve, and would do it with the same 401 as a forged
  token.

  What replaces it, because something must:

    * `active` must be exactly `true`.
    * `exp` is re-checked locally. A provider that says `active` while handing
      back a past `exp` is contradicting itself, and the arithmetic wins.
    * `aud` is checked against `Scheduling.Auth.trusted_audiences/0`. An
      introspection endpoint answers "is this token live", never "is this token
      for you", so without this any client of the realm could act here.

  Tenancy and roles are enforced downstream by `ApiAuth`, unchanged.

  **Known gap:** RFC 7662 does not require `aud` in the response, and a token
  whose response omits it is accepted. Rejecting instead would make the API
  depend on an optional field, and get us back to the outage this module
  exists to fix. It means a provider that never sends `aud` reduces the check
  to "any live token from this realm, carrying a role we recognise". Worth
  tightening once ac-core's actual response shape is on record — the absence
  is logged so it is visible rather than assumed.
  """

  require Logger

  alias Scheduling.Auth
  alias Scheduling.Auth.Tokens

  @doc """
  Whether to attempt introspection when JWT validation fails.

  On by default. The fallback costs a round-trip only on tokens that already
  failed, so leaving it on is the cheap direction; `OIDC_INTROSPECTION=false`
  turns it off for a deployment whose provider definitely issues JWTs.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:scheduling, Scheduling.Auth, []) |> Keyword.get(:introspection) do
      nil -> true
      value -> value
    end
  end

  @doc """
  Asks the provider whether `token` is live, and returns its claims.

  The claims map is shaped like a decoded JWT's — string keys, provider
  extras merged in at the top level — so `Scheduling.Auth.Identity.from_claims/2`
  reads an introspected token and a JWT identically.
  """
  @spec validate(String.t()) :: {:ok, map()} | {:error, Tokens.error()}
  def validate(token) when is_binary(token) do
    case Oidcc.introspect_token(
           token,
           Auth.provider_name(),
           Auth.client_id(),
           Auth.client_secret(),
           %{client_self_only: false}
         ) do
      {:ok, introspection} -> interpret(introspection)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp interpret(%Oidcc.TokenIntrospection{active: true} = introspection) do
    claims = claims(introspection)

    cond do
      expired?(claims["exp"]) ->
        # The provider said active and also handed us an exp in the past.
        # Trust the arithmetic over the flag.
        Logger.warning("Introspection reported an active token whose exp has passed")
        {:error, :token_expired}

      not audience_permitted?(claims["aud"]) ->
        Logger.info("Rejected introspected token: audience #{inspect(claims["aud"])}")
        {:error, :invalid_token}

      true ->
        {:ok, claims}
    end
  end

  defp interpret(%Oidcc.TokenIntrospection{active: _inactive}) do
    # Expired, revoked, or never issued — RFC 7662 §2.2 deliberately does not
    # distinguish them, and neither should the response we give the caller.
    #
    # Logged even though it says nothing the caller does not already know,
    # because of what its absence would mean here. This is the most common
    # outcome by far, and without a line for it the fallback leaves no trace at
    # all on the path it takes most often — so "introspection ran and the
    # provider said no" and "introspection never ran" look identical from the
    # log. That is exactly the question someone debugging a rejected token
    # needs answered, and working it out from request latency is not a
    # reasonable thing to ask of them.
    Logger.info("Introspection reported the token is not active")
    {:error, :invalid_token}
  end

  # `extra` carries every claim outside RFC 7662's registered set, which is
  # where a provider's own claims live — `astrum_roles`, `astrum_org_id`,
  # `astrum_location`. They go at the top level, because that is the depth
  # `Identity.from_claims/2` reads a JWT's claims at.
  defp claims(%Oidcc.TokenIntrospection{} = introspection) do
    introspection.extra
    |> Map.merge(
      %{
        "sub" => introspection.sub,
        "aud" => introspection.aud,
        "iss" => introspection.iss,
        "exp" => introspection.exp,
        "iat" => introspection.iat,
        "nbf" => introspection.nbf,
        "jti" => introspection.jti,
        "client_id" => introspection.client_id,
        "scope" => introspection.scope
      }
      |> Map.reject(fn {_key, value} -> value in [:undefined, nil] end)
    )
  end

  defp expired?(exp) when is_integer(exp), do: exp <= System.system_time(:second)
  defp expired?(_exp), do: false

  # Absent audience is permitted — see the known gap in the moduledoc. Logged
  # rather than silent, because this is the one path where a token is accepted
  # without anything having confirmed it was meant for this deployment.
  defp audience_permitted?(nil) do
    Logger.info("Introspection response carried no audience; accepting on roles alone")
    true
  end

  defp audience_permitted?(aud) do
    trusted = Auth.trusted_audiences()

    aud
    |> List.wrap()
    |> Enum.any?(&(&1 in trusted))
  end

  defp unavailable(reason) do
    # An introspection endpoint we cannot reach is our outage, not a bad
    # token — the same reading `Tokens.client_context/0` gives a provider that
    # has not discovered yet. Returning :invalid_token here would tell a
    # correct caller their credentials are wrong.
    Logger.error("Token introspection failed: #{inspect(reason)}")
    {:error, :provider_unavailable}
  end
end
