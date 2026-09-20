defmodule SchedulingWeb.Plugs.RateLimitTest do
  @moduledoc """
  The quota, and the reason it sits ahead of authentication.

  ac-core issues opaque access tokens, so a bearer token that fails JWT
  validation costs an introspection round-trip measured at 1.3–1.7 seconds —
  and a refusal is deliberately never cached, because caching one would extend
  an outage. So **an invalid token is the expensive request**. A limit applied
  after authentication would protect the cheap path and leave the costly one
  open, which is the wrong way round.

  `async: false` — the counter is a named ETS table and application env.
  """
  use SchedulingWeb.ConnCase, async: false

  import Scheduling.OidcProvider

  alias Scheduling.RateLimit

  setup do
    original = Application.get_env(:scheduling, Scheduling.Api)

    Application.put_env(:scheduling, Scheduling.Api,
      rate_limit_enabled: true,
      rate_limit: 3,
      rate_limit_window_seconds: 60
    )

    RateLimit.clear()
    on_exit(fn -> Application.put_env(:scheduling, Scheduling.Api, original) end)
    :ok
  end

  defp get_with(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(~p"/api/v1/offices")
  end

  describe "the quota" do
    test "allows up to the limit and refuses the next" do
      for _ <- 1..3, do: assert(get_with("tok-a").status != 429)

      conn = get_with("tok-a")
      assert conn.status == 429
      assert json_response(conn, 429)["error"]["code"] == "rate_limited"
    end

    test "is per token, not global" do
      # One integrator's bad afternoon must not lock out everybody else.
      for _ <- 1..4, do: get_with("noisy")

      assert get_with("quiet").status != 429
    end

    test "says when to come back" do
      # A client that honours Retry-After backs off correctly instead of
      # guessing — the difference between calming a retry storm and shaping it.
      for _ <- 1..4, do: get_with("tok-b")

      conn = get_with("tok-b")
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
      assert json_response(conn, 429)["error"]["details"]["retry_after_seconds"] > 0
    end
  end

  describe "where it sits in the pipeline" do
    # Auth has to be ON for this to mean anything. With it off, ApiAuth is a
    # no-op and every request succeeds, so "the limiter runs before
    # authentication" is not being tested at all — only that it runs.
    setup :setup_oidc_provider

    test "a rejected token is counted, which is the entire point" do
      # These tokens never authenticate. If the limiter ran after ApiAuth they
      # would never be counted and the expensive path would be unprotected —
      # and the expensive path is precisely the one an invalid token takes,
      # because it costs an introspection round-trip that is never cached.
      for _ <- 1..3, do: assert(get_with("garbage").status == 401)

      assert get_with("garbage").status == 429
    end

    test "a request with no token is not counted" do
      # It is refused immediately without asking the provider anything, so it
      # is cheap and needs no quota. Counting it would let an unauthenticated
      # flood consume a quota that protects nothing.
      for _ <- 1..10, do: assert(get(build_conn(), ~p"/api/v1/offices").status == 401)

      assert RateLimit.check(RateLimit.key_for_token("anything")) == :ok
    end
  end

  describe "switching it off" do
    test "lets everything through" do
      Application.put_env(:scheduling, Scheduling.Api, rate_limit_enabled: false)

      for _ <- 1..10, do: assert(get_with("unlimited").status != 429)
    end
  end

  describe "the counter itself" do
    test "a caller that cannot be counted is allowed, not refused" do
      # A limiter that cannot count must not become an outage of its own.
      RateLimit.clear()
      assert RateLimit.check("some-key") == :ok
    end

    test "clear/0 lifts the limit immediately" do
      for _ <- 1..4, do: get_with("tok-c")
      assert get_with("tok-c").status == 429

      RateLimit.clear()
      assert get_with("tok-c").status != 429
    end

    test "the raw token is never a key" do
      RateLimit.check(RateLimit.key_for_token("super-secret-token"))

      dumped = :ets.tab2list(RateLimit) |> inspect(limit: :infinity)
      refute dumped =~ "super-secret-token"
    end
  end
end
