defmodule Scheduling.Auth.LoginRoleClaimsTest do
  @moduledoc """
  `identity_from_login/1` reads roles from the ID token when they are there, and
  only falls back to the access token when they are not.

  The fallback used to fire on every sign-in against any provider that is not
  Keycloak, because the claims it checked were hardcoded to Keycloak's two
  shapes while `Auth.role_claims/0` is configurable. Against ac-core, whose
  roles live in `astrum_roles`, that meant a wasted access-token validation and
  a "Rejected bearer token" line logged on each *successful* login — noise that
  makes a genuine bearer failure impossible to pick out.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Scheduling.Auth
  alias Scheduling.Auth.Tokens

  # Evidence that the access-token fallback ran. Either message will do: with a
  # provider worker running it reaches validation and logs a rejection; without
  # one it stops at `client_context/0` and logs unavailability. The point is
  # that a login carrying roles on its ID token should produce neither.
  @attempted ~r/Rejected bearer token|OIDC provider unavailable/

  setup do
    saved = Application.get_env(:scheduling, Auth)
    on_exit(fn -> Application.put_env(:scheduling, Auth, saved) end)
    :ok
  end

  defp configure(role_claims) do
    Application.put_env(:scheduling, Auth,
      issuer: "https://idp.example",
      client_id: "scheduling",
      client_secret: "shh",
      role_claims: role_claims
    )
  end

  # A token whose access half is deliberately not a JWT: if anything tries to
  # validate it, that attempt is visible in the log.
  defp token(id_claims) do
    %Oidcc.Token{
      id: %Oidcc.Token.Id{token: "id-token", claims: id_claims},
      access: %Oidcc.Token.Access{token: "not-a-jwt", expires: 3600, type: "Bearer"},
      refresh: :none,
      scope: ["openid"]
    }
  end

  describe "roles present on the ID token" do
    test "astrum_roles is read without touching the access token" do
      configure(["astrum_roles", "roles", "realm_access.roles"])

      claims = %{
        "sub" => "u1",
        "email" => "op@example.org",
        "astrum_roles" => ["admin", "org_admin"]
      }

      log =
        capture_log(fn ->
          identity = Tokens.identity_from_login(token(claims))
          assert "admin" in identity.roles
        end)

      refute log =~ @attempted,
             "an ID token carrying astrum_roles must not trigger the access-token fallback"
    end

    test "no access-token validation is attempted for a claim under a dotted path" do
      configure(["astrum_roles", "realm_access.roles"])

      claims = %{
        "sub" => "u2",
        "email" => "k@example.org",
        "realm_access" => %{"roles" => ["operator"]}
      }

      log =
        capture_log(fn ->
          identity = Tokens.identity_from_login(token(claims))
          assert "operator" in identity.roles
        end)

      refute log =~ @attempted,
             "the dotted path realm_access.roles must match the realm_access key"
    end

    test "a provider-specific claim name is honoured once configured" do
      configure(["tenant_grants"])

      claims = %{"sub" => "u3", "email" => "x@example.org", "tenant_grants" => ["viewer"]}

      log =
        capture_log(fn ->
          identity = Tokens.identity_from_login(token(claims))
          assert "viewer" in identity.roles
        end)

      refute log =~ @attempted
    end
  end

  describe "roles absent from the ID token" do
    test "falls back to the access token, and survives that failing" do
      configure(["astrum_roles"])

      claims = %{"sub" => "u4", "email" => "y@example.org"}

      # The fallback is correct here — there genuinely are no roles on the ID
      # token. It fails because the access token is not a JWT, and the login
      # must still produce an identity rather than crashing.
      identity = Tokens.identity_from_login(token(claims))

      assert identity.subject == "u4"
      assert identity.roles == []
    end
  end
end
