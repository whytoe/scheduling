defmodule Scheduling.Auth.IdentityTest do
  use ExUnit.Case, async: true

  alias Scheduling.Auth.Identity

  describe "from_claims/2 — provider claim shapes" do
    test "reads Astrum's flat astrum_roles claim" do
      identity =
        Identity.from_claims(
          %{"sub" => "u1", "astrum_roles" => ["operator"], "email" => "a@b.c"},
          "scheduling"
        )

      assert identity.roles == ["operator"]
      assert identity.type == :user
    end

    test "captures Astrum's org and tenant claims" do
      identity =
        Identity.from_claims(%{
          "sub" => "u1",
          "email" => "a@b.c",
          "astrum_org" => "Northside Clinic",
          "astrum_org_id" => "org-1",
          "astrum_tenant" => "northside"
        })

      assert identity.org == "Northside Clinic"
      assert identity.org_id == "org-1"
      assert identity.tenant == "northside"
    end

    test "reads a plain top-level roles claim" do
      identity = Identity.from_claims(%{"sub" => "u1", "roles" => ["viewer"], "email" => "a@b.c"})

      assert identity.roles == ["viewer"]
    end

    test "unions roles across placements when a token carries more than one" do
      identity =
        Identity.from_claims(
          %{
            "sub" => "u1",
            "email" => "a@b.c",
            "astrum_roles" => ["operator"],
            "realm_access" => %{"roles" => ["viewer"]}
          },
          "scheduling"
        )

      assert Enum.sort(identity.roles) == ["operator", "viewer"]
    end

    test "treats a claim sent as JSON null as absent" do
      # oidcc decodes JSON null to the atom :null, not nil. A provider that
      # sends "email": null rather than omitting the key would otherwise look
      # like a signed-in human, and store :null as their email address.
      identity =
        Identity.from_claims(%{
          "sub" => "svc",
          "azp" => "intake-bridge",
          "email" => :null,
          "sid" => :null,
          "name" => :null,
          "astrum_roles" => ["service"]
        })

      assert identity.type == :service
      assert identity.email == nil
      assert identity.name == nil
      assert Identity.label(identity) == "svc"
    end

    test "ignores a null role list rather than crashing on it" do
      identity =
        Identity.from_claims(%{"sub" => "u1", "email" => "a@b.c", "astrum_roles" => :null})

      assert identity.roles == []
    end

    test "a token with roles in no known placement grants nothing" do
      identity =
        Identity.from_claims(%{
          "sub" => "u1",
          "email" => "a@b.c",
          "some_other_roles" => ["admin"]
        })

      assert identity.roles == []
      refute Identity.can_read?(identity)
    end
  end

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

    test "downcases roles so provider casing doesn't decide access" do
      identity =
        Identity.from_claims(%{"sub" => "u1", "astrum_roles" => ["Operator"], "email" => "a@b.c"})

      assert identity.roles == ["operator"]
      assert Identity.has_role?(identity, "operator")
    end

    test "treats a token with no end-user identity as a service token" do
      # No email, no sid, no preferred_username — a client-credentials grant.
      identity =
        Identity.from_claims(%{
          "sub" => "b3f1e0c2-0000-4000-8000-000000000001",
          "azp" => "intake-bridge",
          "astrum_roles" => ["service"]
        })

      assert identity.type == :service
      assert Identity.actor(identity) == {"service", "intake-bridge"}
    end

    test "a session id alone is enough to mark a token as a user" do
      identity = Identity.from_claims(%{"sub" => "u1", "sid" => "session-1"})

      assert identity.type == :user
    end

    test "still treats Keycloak's service-account username as a service token" do
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
      identity =
        Identity.from_claims(%{
          "sub" => "u1",
          "preferred_username" => "acasey",
          "email" => "a@b.c"
        })

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
      admin =
        Identity.from_claims(%{"sub" => "u1", "astrum_roles" => ["admin"], "email" => "a@b.c"})

      assert Identity.has_role?(admin, "operator")
      assert Identity.has_role?(admin, "viewer")
      assert Identity.has_role?(admin, "service")
    end

    test "operator does not satisfy admin" do
      operator =
        Identity.from_claims(%{"sub" => "u1", "astrum_roles" => ["operator"], "email" => "a@b.c"})

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
            "astrum_org" => "Northside Clinic",
            "astrum_org_id" => "org-1",
            "astrum_tenant" => "northside",
            "astrum_roles" => ["operator"]
          },
          "scheduling"
        )

      assert identity |> Identity.to_session() |> Identity.from_session() == identity
    end

    test "carries no tokens into the session" do
      identity = Identity.from_claims(%{"sub" => "u1", "email" => "a@b.c"})
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
      # No name/username/email is the service-token case; the subject is all
      # there is, and it is what the navbar would show if one ever rendered.
    end
  end
end
