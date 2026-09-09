defmodule Scheduling.Auth.IntrospectionTest do
  @moduledoc """
  The fallback that decides whether `/api/v1` is usable at all.

  `Scheduling.Auth.Tokens` validates bearer tokens against the provider's
  JWKS, which only works if the access token is a signed JWT. OIDC does not
  require that — only the ID token has a defined shape — and ac-core appears
  to issue opaque access tokens: in production its ID token validated while
  its access token failed `:no_matching_key`, from the same token response.

  The failure that makes this worth testing carefully is its *shape*. Browser
  SSO keeps working, because that path only needs the ID token. So a
  deployment can look completely healthy from the UI while every integration
  is locked out.

  `async: false` — these point `Scheduling.Auth` at a fake provider, which is
  application env.
  """
  use Scheduling.DataCase, async: false

  import Scheduling.OidcProvider

  require Logger

  alias Scheduling.Auth.Introspection
  alias Scheduling.Auth.Tokens

  setup :setup_oidc_provider

  # Not a JWT at all — three dots' worth of nothing. This is what an opaque
  # access token looks like to us, and it must never validate locally.
  @opaque_token "aXQgaXMgb3BhcXVlLCB0aGF0IGlzIHRoZSBwb2ludA"

  defp active_response(overrides \\ %{}) do
    Map.merge(
      %{
        "active" => true,
        "sub" => "svc-checkin",
        # A DIFFERENT client to the one introspecting. That is the normal case
        # here and the reason `client_self_only` is off: every token /api/v1
        # sees was issued to somebody else. oidcc's default would 401 all of it.
        "client_id" => "checkin-bridge",
        "aud" => client_id(),
        "exp" => System.system_time(:second) + 300,
        "scope" => "openid roles",
        "astrum_roles" => ["service"]
      },
      overrides
    )
  end

  describe "an opaque access token" do
    test "is accepted when the provider says it is active", ctx do
      counter = stub_introspection(ctx, active_response())

      assert {:ok, identity} = Tokens.validate(@opaque_token)
      assert identity.subject == "svc-checkin"
      assert "service" in identity.roles
      assert :counters.get(counter, 1) == 1
    end

    test "carries the provider's own claims through", ctx do
      # RFC 7662 registers a handful of fields; everything else — which is
      # where astrum_* lives — arrives in `extra`. If those were dropped, an
      # introspected token would authenticate and then be denied by every role
      # check, which reads as a permissions problem rather than a parsing one.
      stub_introspection(
        ctx,
        active_response(%{"astrum_roles" => ["admin"], "astrum_org_id" => "org-7"})
      )

      assert {:ok, identity} = Tokens.validate(@opaque_token)
      assert "admin" in identity.roles
      assert identity.tenancy_id == "org-7"
    end

    test "is rejected when the provider says it is not active", ctx do
      # Expired, revoked, or never issued. RFC 7662 §2.2 deliberately does not
      # distinguish them and neither do we.
      stub_introspection(ctx, %{"active" => false})

      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)
    end

    test "and says so in the log, so the path is not invisible", ctx do
      # The most common outcome. Without a line for it, "introspection ran and
      # was told no" is indistinguishable from "introspection never ran" — and
      # that is precisely the question when a token is being rejected and
      # nobody knows why. Established by having to answer it from request
      # latency once, in production.
      stub_introspection(ctx, %{"active" => false})

      # The suite runs at :warning and this is deliberately an :info — normal
      # traffic, not a problem. Lift the level for this process only; the
      # primary level filters before any capture handler sees the message, so
      # capture_log's own :level option cannot reach it.
      # The primary Logger level filters before any capture handler sees a
      # message, so capture_log's own :level option cannot reach an :info while
      # the suite runs at :warning. Lower the primary level for this test only.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_token} = Tokens.validate(@opaque_token)
        end)

      assert log =~ "not active"
    end

    test "is rejected when the response omits active entirely", ctx do
      stub_introspection(ctx, %{"sub" => "svc-checkin"})

      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)
    end
  end

  describe "tokens belonging to other clients" do
    test "are accepted — which is the entire point of the API", ctx do
      # oidcc defaults client_self_only: true, accepting a response only when
      # its client_id is ours. Correct for a client checking its own tokens;
      # here it would reject every token /api/v1 exists to serve, with the same
      # 401 a forged token gets. `checkin-bridge` is the whole scenario.
      stub_introspection(ctx, active_response(%{"client_id" => "checkin-bridge"}))

      assert {:ok, identity} = Tokens.validate(@opaque_token)
      assert identity.subject == "svc-checkin"
    end
  end

  describe "trusting the provider only as far as it should be trusted" do
    test "an active token whose exp has passed is expired, not valid", ctx do
      # Contradictory, and the arithmetic wins. A provider that says `active`
      # while handing over a past `exp` is buggy, and the failure direction
      # matters more than the diagnosis.
      stub_introspection(ctx, active_response(%{"exp" => System.system_time(:second) - 60}))

      assert {:error, :token_expired} = Tokens.validate(@opaque_token)
    end

    test "a token issued to another client is refused", ctx do
      # The introspection endpoint answers "is this token live", not "is this
      # token for you". It will confirm a token minted for any client of the
      # realm; accepting that would let any of them act here.
      stub_introspection(ctx, active_response(%{"aud" => "some-other-app"}))

      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)
    end

    test "a response with no audience at all is still accepted", ctx do
      # `aud` is optional in RFC 7662. Requiring it would make this depend on a
      # field the spec lets a provider omit.
      stub_introspection(ctx, active_response() |> Map.delete("aud"))

      assert {:ok, _identity} = Tokens.validate(@opaque_token)
    end
  end

  describe "the JWT fast path" do
    test "a valid JWT never reaches the introspection endpoint", ctx do
      # The property that keeps an IdP round-trip off every API request.
      counter = stub_introspection(ctx, active_response())
      token = access_token(ctx, %{}, roles: ["operator"])

      assert {:ok, identity} = Tokens.validate(token)
      assert "operator" in identity.roles
      assert :counters.get(counter, 1) == 0
    end

    test "an expired JWT is not given a second opinion", ctx do
      # Its `exp` is signed. Asking the provider cannot make it later, and a
      # provider that disagreed would be overriding a signature we verified.
      counter = stub_introspection(ctx, active_response())
      token = access_token(ctx, %{"exp" => System.system_time(:second) - 60})

      assert {:error, :token_expired} = Tokens.validate(token)
      assert :counters.get(counter, 1) == 0
    end
  end

  describe "switching it off" do
    test "leaves an opaque token rejected, without calling the endpoint", ctx do
      counter = stub_introspection(ctx, active_response())
      put_auth_option(:introspection, false)

      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)
      assert :counters.get(counter, 1) == 0
    end
  end

  describe "when the endpoint itself fails" do
    test "the module reports it as an outage", ctx do
      # At this layer the distinction is real and worth keeping: we could not
      # ask, which is not the same as being told no.
      stub_introspection(ctx, %{"error" => "server_error"}, 500)

      assert {:error, :provider_unavailable} = Introspection.validate(@opaque_token)
    end

    test "but the original rejection stands rather than becoming a 503", ctx do
      # The fallback can only upgrade a rejection to an acceptance. Letting
      # :provider_unavailable through would answer 503 to every forged token —
      # and to every token at all against a provider with no introspection
      # endpoint, where there was never a second opinion to be had.
      stub_introspection(ctx, %{"error" => "server_error"}, 500)

      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)
    end

    test "so does a forged JWT when introspection cannot be reached", ctx do
      # The regression this rule exists to prevent: a token we *know* is bad
      # must not start reporting the provider as broken.
      stub_introspection(ctx, %{"error" => "server_error"}, 500)
      forged = sign(JOSE.JWK.generate_key({:rsa, 2048}), %{"sub" => "attacker"})

      assert {:error, :invalid_token} = Tokens.validate(forged)
    end
  end
end
