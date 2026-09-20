defmodule Scheduling.Auth.IntrospectionCacheTest do
  @moduledoc """
  The cache that makes the API usable, and the revocation window that buys.

  ac-core issues opaque access tokens, so every `/api/v1` bearer token takes
  the introspection path — measured at 1.3 to 1.7 seconds per call once we
  began authenticating properly. Without a cache the API is not slow, it is
  unusable.

  What that costs is stated rather than hidden: a token revoked at the provider
  keeps working here until its cached answer lapses. These tests pin the shape
  of that trade — short, bounded, positive-only, capped by `exp`.

  `async: false` — the cache is a named ETS table and application env.
  """
  use Scheduling.DataCase, async: false

  import Scheduling.OidcProvider

  alias Scheduling.Auth.Introspection
  alias Scheduling.Auth.Introspection.Cache
  alias Scheduling.Auth.Tokens

  setup :setup_oidc_provider

  @opaque_token "not-a-jwt-just-an-opaque-string"

  defp active_response(overrides \\ %{}) do
    Map.merge(
      %{
        "active" => true,
        "sub" => "svc-cached",
        "client_id" => "checkin-bridge",
        "aud" => client_id(),
        "exp" => System.system_time(:second) + 3600,
        "astrum_roles" => ["service"]
      },
      overrides
    )
  end

  describe "the round-trip it removes" do
    test "a second validation does not ask the provider again", ctx do
      counter = stub_introspection(ctx, active_response())

      assert {:ok, _} = Tokens.validate(@opaque_token)
      assert {:ok, _} = Tokens.validate(@opaque_token)
      assert {:ok, _} = Tokens.validate(@opaque_token)

      assert :counters.get(counter, 1) == 1
    end

    test "a different token is its own question", ctx do
      counter = stub_introspection(ctx, active_response())

      assert {:ok, _} = Tokens.validate("opaque-one")
      assert {:ok, _} = Tokens.validate("opaque-two")

      assert :counters.get(counter, 1) == 2
    end
  end

  describe "the cost of the window, stated" do
    test "a token keeps working inside the window after the provider turns against it", ctx do
      # This is the price of the cache and it should be asserted, not implied.
      # Revocation takes effect within ttl_seconds/0, not immediately. An
      # operator can act on that sentence; they cannot act on a surprise.
      counter = :counters.new(1, [])
      test_pid = self()

      Bypass.stub(ctx.bypass, "POST", "/protocol/openid-connect/token/introspect", fn conn ->
        :counters.add(counter, 1, 1)

        body =
          if :counters.get(counter, 1) == 1, do: active_response(), else: %{"active" => false}

        send(test_pid, {:asked, :counters.get(counter, 1)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:ok, _} = Tokens.validate(@opaque_token)
      assert_receive {:asked, 1}

      # The provider would now refuse it. We do not ask, so it still works.
      assert {:ok, _} = Tokens.validate(@opaque_token)
      assert :counters.get(counter, 1) == 1

      # Until the window is dropped, at which point the refusal lands.
      Cache.clear()
      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "what is not cached" do
    test "a refusal is asked again every time", ctx do
      # Caching a refusal would let a momentary provider error pin a
      # legitimate caller out for the whole window, with nothing they could do.
      counter = stub_introspection(ctx, %{"active" => false})

      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)
      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)

      assert :counters.get(counter, 1) == 2
    end

    test "an outage is asked again every time", ctx do
      counter = stub_introspection(ctx, %{"error" => "server_error"}, 500)

      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)
      assert {:error, :invalid_token} = Tokens.validate(@opaque_token)

      assert :counters.get(counter, 1) == 2
    end
  end

  describe "the window" do
    test "an expired entry is a miss, not a hit" do
      Cache.put(@opaque_token, %{"sub" => "u", "exp" => System.system_time(:second) - 1})
      assert Cache.fetch(@opaque_token) == :miss
    end

    test "a live entry is a hit" do
      claims = %{"sub" => "u", "exp" => System.system_time(:second) + 3600}
      Cache.put(@opaque_token, claims)
      assert {:ok, ^claims} = Cache.fetch(@opaque_token)
    end

    test "the token's own exp caps the window" do
      # A token expiring in two seconds must not be honoured for the full TTL.
      soon = System.system_time(:second) + 2
      Cache.put(@opaque_token, %{"sub" => "u", "exp" => soon})

      assert {:ok, _} = Cache.fetch(@opaque_token)

      # Walking past the token's expiry, but well inside the TTL.
      Process.sleep(2_100)
      assert Cache.fetch(@opaque_token) == :miss
      assert Cache.ttl_seconds() > 3, "this test is meaningless if the TTL is tiny"
    end

    test "a response with no exp still expires" do
      # An absent exp must not mean "forever" — that is the revocation hole
      # this whole design exists to avoid.
      Cache.put(@opaque_token, %{"sub" => "u"})
      assert {:ok, _} = Cache.fetch(@opaque_token)
      assert Cache.ttl_seconds() <= 300, "the revocation window has grown past reason"
    end
  end

  describe "what is stored" do
    test "the raw token never appears in the table" do
      # A cache keyed on tokens is a table of live credentials, dumped
      # wholesale by any crash report that inspects it.
      Cache.put(@opaque_token, %{"sub" => "u"})

      dumped = :ets.tab2list(Cache) |> inspect(limit: :infinity)
      refute dumped =~ @opaque_token
    end
  end

  describe "switching it off" do
    test "clear/0 removes the window immediately", ctx do
      counter = stub_introspection(ctx, active_response())

      assert {:ok, _} = Tokens.validate(@opaque_token)
      Cache.clear()
      assert {:ok, _} = Tokens.validate(@opaque_token)

      assert :counters.get(counter, 1) == 2
    end

    test "fetch/1 is a miss when the cache was never started" do
      # The table is absent when disabled. A miss is always safe — it costs a
      # round-trip and nothing else.
      assert Introspection.credentials() |> elem(0) != nil
      assert Cache.fetch("never-seen-token") == :miss
    end
  end
end
