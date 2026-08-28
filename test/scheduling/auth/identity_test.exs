defmodule Scheduling.Auth.IdentityTest do
  use ExUnit.Case, async: true

  alias Scheduling.Auth.Identity

  describe "from_claims/2" do
    test "reads realm roles and this client's roles as one set" do
      claims = %{
        "sub" => "u1",
        "realm_access" => %{"roles" => ["operator", "offline_access"]},
        "resource_access" => %{
          "scheduling" => %{"roles" => ["admin"]},
          "other-app" => %{"roles" => ["should-not-appear"]}
        }
      }

      identity = Identity.from_claims(claims, "scheduling")

      assert "operator" in identity.roles
      assert "admin" in identity.roles
      refute "should-not-appear" in identity.roles
    end

    test "carries unrecognised roles through without granting anything" do
      identity =
        Identity.from_claims(%{"sub" => "u1", "realm_access" => %{"roles" => ["billing"]}})

      assert identity.roles == ["billing"]
      refute Identity.can_read?(identity)
    end

    test "downcases roles so realm casing doesn't decide access" do
      identity =
        Identity.from_claims(%{"sub" => "u1", "realm_access" => %{"roles" => ["Operator"]}})

      assert identity.roles == ["operator"]
      assert Identity.has_role?(identity, "operator")
    end

    test "treats a service-account username as a service token" do
      identity =
        Identity.from_claims(%{
          "sub" => "uuid",
          "azp" => "intake-bridge",
          "preferred_username" => "service-account-intake-bridge"
        })

      assert identity.type == :service
      assert Identity.actor(identity) == {"service", "intake-bridge"}
    end

    test "treats a human username as a user token, attributed by subject" do
      identity = Identity.from_claims(%{"sub" => "u1", "preferred_username" => "acasey"})

      assert identity.type == :user
      assert Identity.actor(identity) == {"user", "u1"}
    end

    test "falls back to the subject when a service token has no azp" do
      identity =
        Identity.from_claims(%{"sub" => "uuid", "preferred_username" => "service-account-x"})

      assert Identity.actor(identity) == {"service", "uuid"}
    end
  end

  describe "roles" do
    test "admin satisfies every role" do
      admin = Identity.from_claims(%{"sub" => "u1", "realm_access" => %{"roles" => ["admin"]}})

      assert Identity.has_role?(admin, "operator")
      assert Identity.has_role?(admin, "viewer")
      assert Identity.has_role?(admin, "service")
    end

    test "operator does not satisfy admin" do
      operator =
        Identity.from_claims(%{"sub" => "u1", "realm_access" => %{"roles" => ["operator"]}})

      refute Identity.has_role?(operator, "admin")
      assert Identity.can_read?(operator)
    end
  end

  describe "session round-trip" do
    test "restores the same identity" do
      identity =
        Identity.from_claims(
          %{
            "sub" => "u1",
            "preferred_username" => "acasey",
            "email" => "acasey@example.org",
            "name" => "A. Casey",
            "azp" => "scheduling",
            "exp" => 123,
            "realm_access" => %{"roles" => ["operator"]}
          },
          "scheduling"
        )

      assert identity |> Identity.to_session() |> Identity.from_session() == identity
    end

    test "carries no tokens into the session" do
      identity = Identity.from_claims(%{"sub" => "u1"})
      session = Identity.to_session(identity)

      refute Enum.any?(Map.keys(session), &(&1 =~ "token"))
    end

    test "returns nil for anything that isn't a serialised identity" do
      assert Identity.from_session(nil) == nil
      assert Identity.from_session(%{}) == nil
      assert Identity.from_session("nonsense") == nil
    end
  end

  describe "label/1" do
    test "prefers name, then username, then email, then subject" do
      assert Identity.label(Identity.from_claims(%{"sub" => "u1", "name" => "A. Casey"})) ==
               "A. Casey"

      assert Identity.label(Identity.from_claims(%{"sub" => "u1", "preferred_username" => "ac"})) ==
               "ac"

      assert Identity.label(Identity.from_claims(%{"sub" => "u1", "email" => "a@b.c"})) == "a@b.c"
      assert Identity.label(Identity.from_claims(%{"sub" => "u1"})) == "u1"
    end
  end
end
