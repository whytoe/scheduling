defmodule Scheduling.Auth.TokensTest do
  # async: false — pointing Scheduling.Auth at the fake provider writes app env.
  use ExUnit.Case, async: false

  import Scheduling.OidcProvider

  alias Scheduling.Auth.Identity
  alias Scheduling.Auth.Tokens

  setup :setup_oidc_provider

  describe "validate/1" do
    test "accepts a well-formed token and names its subject", ctx do
      assert {:ok, %Identity{} = identity} = Tokens.validate(access_token(ctx))

      assert identity.subject == "user-1"
      assert identity.type == :user
      assert identity.roles == ["operator"]
    end

    test "picks up client roles as well as realm roles", ctx do
      token = access_token(ctx, %{}, shape: :keycloak, roles: ["viewer"], client_roles: ["admin"])

      assert {:ok, identity} = Tokens.validate(token)
      assert Enum.sort(identity.roles) == ["admin", "viewer"]
    end

    test "accepts a Keycloak-shaped token without configuration", ctx do
      token = access_token(ctx, %{}, shape: :keycloak, roles: ["admin"])

      assert {:ok, identity} = Tokens.validate(token)
      assert identity.roles == ["admin"]
      assert identity.type == :user
    end

    test "carries the org and tenant claims through validation", ctx do
      assert {:ok, identity} = Tokens.validate(access_token(ctx))

      assert identity.org == "Northside Clinic"
      assert identity.tenant == "northside"
    end

    test "identifies a Keycloak service-account token as a service", ctx do
      assert {:ok, identity} = Tokens.validate(service_token(ctx, %{}, shape: :keycloak))

      assert identity.type == :service
      assert Identity.actor(identity) == {"service", "intake-bridge"}
    end

    test "identifies a client-credentials token as a service", ctx do
      assert {:ok, identity} = Tokens.validate(service_token(ctx))

      assert identity.type == :service
      assert Identity.actor(identity) == {"service", "intake-bridge"}
    end

    test "rejects a token signed by a key the provider does not publish", ctx do
      forged = access_token(ctx, %{}, jwk: JOSE.JWK.generate_key({:rsa, 2048}))

      assert {:error, :invalid_token} = Tokens.validate(forged)
    end

    test "rejects an expired token", ctx do
      past = System.system_time(:second) - 60

      assert {:error, :token_expired} =
               Tokens.validate(access_token(ctx, %{"exp" => past, "iat" => past - 300}))
    end

    test "rejects a token minted for a different audience", ctx do
      assert {:error, :invalid_token} =
               Tokens.validate(access_token(ctx, %{"aud" => "some-other-client"}))
    end

    test "rejects a token from a different issuer", ctx do
      assert {:error, :invalid_token} =
               Tokens.validate(access_token(ctx, %{"iss" => "https://elsewhere.example"}))
    end

    test "rejects an unsigned (alg: none) token", ctx do
      # The classic downgrade: strip the signature and claim no algorithm. The
      # pinned signing_algs list is what makes this a non-event.
      claims =
        Jason.encode!(%{"iss" => ctx.issuer, "sub" => "attacker", "aud" => ctx.client_id})

      unsigned =
        Base.url_encode64(Jason.encode!(%{"alg" => "none", "typ" => "JWT"}), padding: false) <>
          "." <> Base.url_encode64(claims, padding: false) <> "."

      assert {:error, :invalid_token} = Tokens.validate(unsigned)
    end

    test "rejects garbage", ctx do
      assert {:error, :invalid_token} = Tokens.validate("not-a-jwt")
      assert {:error, :invalid_token} = Tokens.validate("")
      _ = ctx
    end
  end
end
