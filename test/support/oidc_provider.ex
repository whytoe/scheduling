defmodule Scheduling.OidcProvider do
  @moduledoc """
  Stands up a fake OpenID Connect provider so the auth path can be tested for
  real rather than mocked out.

  A `Bypass` server serves a discovery document and a JWKS built from an RSA
  key generated for the test; `Scheduling.Auth` is pointed at it and a
  `Oidcc.ProviderConfiguration.Worker` is started against it. Tokens are then
  minted with `access_token/2` and signed by that key.

  Testing through the real `oidcc` validation path — rather than stubbing
  `Scheduling.Auth.Tokens` — is the point. It is what lets a test assert that
  a token signed by the *wrong* key, or carrying the wrong audience, is
  actually rejected. A stub would happily "reject" those without the code
  under test ever checking.

      use SchedulingWeb.ConnCase, async: false
      import Scheduling.OidcProvider

      setup :setup_oidc_provider

      test "rejects a token from a different issuer", ctx do
        token = access_token(ctx, %{"iss" => "https://elsewhere.example"})
        ...
      end

  Tests using this must be `async: false`: pointing `Scheduling.Auth` at the
  fake provider means writing application env, which is global.
  """

  @client_id "scheduling"
  @client_secret "test-secret"

  @doc "Setup callback. Returns bypass, issuer, jwk and client_id in the context."
  def setup_oidc_provider(_context \\ %{}) do
    bypass = Bypass.open()
    issuer = "http://localhost:#{bypass.port}"
    jwk = JOSE.JWK.generate_key({:rsa, 2048})

    stub_discovery(bypass, issuer, jwk)
    put_auth_config(issuer)
    start_provider!()

    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:scheduling, Scheduling.Auth) end)

    %{bypass: bypass, issuer: issuer, jwk: jwk, client_id: @client_id}
  end

  @doc """
  Mints a signed access token.

  `overrides` replaces any default claim, so a test can produce an expired,
  mis-audienced or mis-issued token by naming just the claim it wants wrong.

  `opts[:shape]` selects the provider's claim vocabulary:

    * `:astrum` (default) — `astrum_roles`, `sid`, no `preferred_username`.
      This is the deployment target (ac-core).
    * `:keycloak` — `realm_access.roles` plus `preferred_username`.

  Both are exercised, because `Scheduling.Auth.role_claims/0` is meant to
  cover either without configuration. Pass `roles:` for the roles to grant and
  `client_roles:` for Keycloak's `resource_access.<client_id>` placement.
  """
  def access_token(context, overrides \\ %{}, opts \\ []) do
    now = System.system_time(:second)
    roles = Keyword.get(opts, :roles, ["operator"])

    base = %{
      "iss" => context.issuer,
      "sub" => "user-1",
      "aud" => @client_id,
      "azp" => @client_id,
      "exp" => now + 300,
      "iat" => now,
      "nbf" => now - 5,
      "email" => "acasey@example.org",
      "name" => "A. Casey"
    }

    claims =
      base
      |> Map.merge(user_shape(Keyword.get(opts, :shape, :astrum), roles))
      |> put_client_roles(opts)
      |> Map.merge(overrides)

    sign(Keyword.get(opts, :jwk, context.jwk), claims)
  end

  @doc """
  Mints a token shaped like the client-credentials grant: no end-user identity
  on it at all — no `email`, no `sid`, no `preferred_username` — which is what
  `Scheduling.Auth.Identity` keys off to classify it as a service.

  `shape: :keycloak` instead produces Keycloak's
  `preferred_username: "service-account-<client>"` marker.
  """
  def service_token(context, overrides \\ %{}, opts \\ []) do
    client = Keyword.get(opts, :client, "intake-bridge")
    opts = Keyword.put_new(opts, :roles, ["service"])

    service_claims =
      case Keyword.get(opts, :shape, :astrum) do
        :keycloak -> %{"preferred_username" => "service-account-#{client}"}
        :astrum -> %{}
      end

    access_token(
      context,
      Map.merge(
        %{
          "sub" => "b3f1e0c2-0000-4000-8000-000000000001",
          "azp" => client,
          "email" => nil,
          "sid" => nil,
          "name" => nil
        },
        Map.merge(service_claims, overrides)
      ),
      opts
    )
  end

  @doc "Signs arbitrary claims with a key — used to forge a wrong-key token."
  def sign(jwk, claims) do
    {_meta, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "test-key"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  @doc "Sets the Authorization header for an API request."
  def with_bearer(conn, token),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

  # Astrum flattens roles into one claim and identifies the session with `sid`;
  # Keycloak nests them under `realm_access` and always sends a username.
  defp user_shape(:astrum, roles) do
    %{
      "astrum_roles" => roles,
      "sid" => "session-1",
      "astrum_org" => "Northside Clinic",
      "astrum_org_id" => "org-1",
      "astrum_tenant" => "northside"
    }
  end

  defp user_shape(:keycloak, roles) do
    %{"realm_access" => %{"roles" => roles}, "preferred_username" => "acasey"}
  end

  defp put_client_roles(claims, opts) do
    case Keyword.get(opts, :client_roles) do
      nil -> claims
      roles -> Map.put(claims, "resource_access", %{@client_id => %{"roles" => roles}})
    end
  end

  defp stub_discovery(bypass, issuer, jwk) do
    jwks = %{
      "keys" => [
        jwk
        |> JOSE.JWK.to_public_map()
        |> elem(1)
        |> Map.merge(%{"kid" => "test-key", "use" => "sig", "alg" => "RS256"})
      ]
    }

    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      body =
        Jason.encode!(%{
          "issuer" => issuer,
          "authorization_endpoint" => issuer <> "/protocol/openid-connect/auth",
          "token_endpoint" => issuer <> "/protocol/openid-connect/token",
          "end_session_endpoint" => issuer <> "/protocol/openid-connect/logout",
          "jwks_uri" => issuer <> "/protocol/openid-connect/certs",
          "userinfo_endpoint" => issuer <> "/protocol/openid-connect/userinfo",
          "introspection_endpoint" => issuer <> "/protocol/openid-connect/token/introspect",
          "response_types_supported" => ["code"],
          "response_modes_supported" => ["query", "fragment", "form_post"],
          "subject_types_supported" => ["public"],
          "id_token_signing_alg_values_supported" => ["RS256"],
          "scopes_supported" => ["openid", "profile", "email", "roles"],
          "claims_supported" => ["sub", "iss", "aud", "exp", "email", "preferred_username"],
          "grant_types_supported" => [
            "authorization_code",
            "client_credentials",
            "refresh_token"
          ],
          "code_challenge_methods_supported" => ["S256"],
          "token_endpoint_auth_methods_supported" => ["client_secret_post", "client_secret_basic"]
        })

      Plug.Conn.resp(Plug.Conn.put_resp_content_type(conn, "application/json"), 200, body)
    end)

    Bypass.stub(bypass, "GET", "/protocol/openid-connect/certs", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(jwks))
    end)
  end

  defp put_auth_config(issuer) do
    Application.put_env(:scheduling, Scheduling.Auth,
      issuer: issuer,
      client_id: @client_id,
      client_secret: @client_secret,
      trusted_audiences: [],
      signing_algs: ["RS256"],
      session_ttl_seconds: 3600
    )
  end

  # The worker is normally supervised by the app, but the app booted with auth
  # disabled. Start one per test, owned by the test process so it goes away
  # with it.
  #
  # `allow_unsafe_http` is oidcc's development quirk. Bypass cannot serve TLS,
  # and oidcc otherwise insists the discovered endpoints be https — correctly,
  # for anything real. It relaxes the transport check only; every signature,
  # issuer, audience and expiry check still runs exactly as in production.
  defp start_provider! do
    ExUnit.Callbacks.start_supervised!(
      {Oidcc.ProviderConfiguration.Worker,
       %{
         issuer: Scheduling.Auth.issuer(),
         name: Scheduling.Auth.provider_name(),
         provider_configuration_opts: %{quirks: %{allow_unsafe_http: true}}
       }}
    )
  end
end
