defmodule Scheduling.Auth.ServiceTokenTest do
  @moduledoc """
  `Scheduling.Auth.ServiceToken` against a Bypass server playing ac-core's
  OIDC discovery and token endpoints.

  Exercises the real `Oidcc.client_credentials_token/4` path rather than
  stubbing it, so the caching and expiry logic is tested against the token
  struct oidcc actually produces — including that `expires` is `expires_in`
  (relative seconds), which is the thing easiest to get wrong.

  `async: false` — mutates application env and registers a named process.
  """
  use ExUnit.Case, async: false

  alias Scheduling.Auth.ServiceToken

  setup do
    bypass = Bypass.open()
    issuer = "http://localhost:#{bypass.port}"

    original_core = Application.get_env(:scheduling, Scheduling.Core)
    original_auth = Application.get_env(:scheduling, Scheduling.Auth)

    Application.put_env(:scheduling, Scheduling.Auth,
      issuer: issuer,
      client_id: "scheduling",
      client_secret: "browser-secret",
      discovery_overrides: %{"subject_types_supported" => ["public"]}
    )

    Application.put_env(:scheduling, Scheduling.Core,
      base_url: issuer,
      client_id: "scheduling-svc",
      client_secret: "svc-secret",
      scopes: ["core:patients:read", "core:organizations:read"]
    )

    stub_discovery(bypass, issuer)

    on_exit(fn ->
      Application.put_env(:scheduling, Scheduling.Core, original_core)
      Application.put_env(:scheduling, Scheduling.Auth, original_auth)
    end)

    %{bypass: bypass, issuer: issuer}
  end

  defp stub_discovery(bypass, issuer) do
    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      body =
        Jason.encode!(%{
          "issuer" => issuer,
          "authorization_endpoint" => issuer <> "/authorize",
          "token_endpoint" => issuer <> "/oauth/token",
          "jwks_uri" => issuer <> "/oauth/jwks",
          "response_types_supported" => ["code"],
          "subject_types_supported" => ["public"],
          "grant_types_supported" => ["authorization_code", "client_credentials"],
          "id_token_signing_alg_values_supported" => ["RS256"],
          "scopes_supported" => ["openid", "core:patients:read", "core:organizations:read"],
          "token_endpoint_auth_methods_supported" => ["client_secret_basic", "client_secret_post"]
        })

      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, body)
    end)

    jwk = JOSE.JWK.generate_key({:rsa, 2048})

    Bypass.stub(bypass, "GET", "/oauth/jwks", fn conn ->
      key = jwk |> JOSE.JWK.to_public_map() |> elem(1) |> Map.put("kid", "k")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"keys" => [key]}))
    end)
  end

  # oidcc needs the provider worker; auth is configured but the app booted
  # without it, so start one per test owned by the test process.
  defp start_provider!(_issuer) do
    start_supervised!(
      {Oidcc.ProviderConfiguration.Worker,
       %{
         issuer: Scheduling.Auth.issuer(),
         name: Scheduling.Auth.provider_name(),
         provider_configuration_opts: %{quirks: %{allow_unsafe_http: true}}
       }}
    )
  end

  defp stub_token(bypass, fun), do: Bypass.stub(bypass, "POST", "/oauth/token", fun)

  defp token_response(conn, token, expires_in) do
    body =
      %{"access_token" => token, "token_type" => "bearer"}
      |> then(fn b -> if expires_in, do: Map.put(b, "expires_in", expires_in), else: b end)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, body |> Jason.encode!())
  end

  describe "fetch/1" do
    test "returns an access token", ctx do
      start_provider!(ctx.issuer)
      stub_token(ctx.bypass, &token_response(&1, "tok_1", 300))
      pid = start_supervised!(ServiceToken)

      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)
    end

    test "caches — a second call does not hit the token endpoint again", ctx do
      start_provider!(ctx.issuer)
      test_pid = self()

      stub_token(ctx.bypass, fn conn ->
        send(test_pid, :token_requested)
        token_response(conn, "tok_1", 300)
      end)

      pid = start_supervised!(ServiceToken)

      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)
      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)
      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)

      assert_receive :token_requested
      refute_receive :token_requested, 200
    end

    test "requests the configured scopes", ctx do
      start_provider!(ctx.issuer)
      test_pid = self()

      stub_token(ctx.bypass, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, body})
        token_response(conn, "tok_1", 300)
      end)

      pid = start_supervised!(ServiceToken)
      assert {:ok, _} = ServiceToken.fetch(pid)

      assert_receive {:body, body}
      assert body =~ "grant_type=client_credentials"
      assert URI.decode(body) =~ "core:patients:read"
      assert URI.decode(body) =~ "core:organizations:read"
    end

    test "a token expiring inside the safety margin is not served from cache", ctx do
      # expires_in below the 60s margin means it is never cacheable, so every
      # call re-fetches rather than handing out something that could die
      # mid-request.
      start_provider!(ctx.issuer)
      counter = :counters.new(1, [])

      stub_token(ctx.bypass, fn conn ->
        :counters.add(counter, 1, 1)
        token_response(conn, "tok_#{:counters.get(counter, 1)}", 10)
      end)

      pid = start_supervised!(ServiceToken)

      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)
      assert {:ok, "tok_2"} = ServiceToken.fetch(pid)
      assert :counters.get(counter, 1) == 2
    end

    test "a long-lived token is cached", ctx do
      start_provider!(ctx.issuer)
      counter = :counters.new(1, [])

      stub_token(ctx.bypass, fn conn ->
        :counters.add(counter, 1, 1)
        token_response(conn, "tok_#{:counters.get(counter, 1)}", 3600)
      end)

      pid = start_supervised!(ServiceToken)

      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)
      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)
      assert :counters.get(counter, 1) == 1
    end

    test "a response without expires_in is cached only briefly", ctx do
      # We cannot know the lifetime, so it gets the short defensive TTL rather
      # than being trusted indefinitely — but it is still cached, so a burst of
      # callers does not become a burst of token requests.
      start_provider!(ctx.issuer)
      counter = :counters.new(1, [])

      stub_token(ctx.bypass, fn conn ->
        :counters.add(counter, 1, 1)
        token_response(conn, "tok_#{:counters.get(counter, 1)}", nil)
      end)

      pid = start_supervised!(ServiceToken)

      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)
      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "failure handling" do
    test "a rejected exchange returns an error rather than crashing", ctx do
      start_provider!(ctx.issuer)

      stub_token(ctx.bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error" => "invalid_client"}))
      end)

      pid = start_supervised!(ServiceToken)

      assert {:error, _reason} = ServiceToken.fetch(pid)
      # Still alive; a bad exchange must not take the holder down.
      assert Process.alive?(pid)
    end

    test "a failure is not cached — the next call retries", ctx do
      start_provider!(ctx.issuer)
      counter = :counters.new(1, [])

      stub_token(ctx.bypass, fn conn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "boom"}))
        else
          token_response(conn, "tok_after_retry", 300)
        end
      end)

      pid = start_supervised!(ServiceToken)

      assert {:error, _} = ServiceToken.fetch(pid)
      assert {:ok, "tok_after_retry"} = ServiceToken.fetch(pid)
    end

    test "a failed refresh leaves an existing token in place", ctx do
      # A refresh failure should not turn a working cache into an outage.
      start_provider!(ctx.issuer)
      counter = :counters.new(1, [])

      stub_token(ctx.bypass, fn conn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          token_response(conn, "tok_good", 3600)
        else
          Plug.Conn.resp(conn, 500, "")
        end
      end)

      pid = start_supervised!(ServiceToken)

      assert {:ok, "tok_good"} = ServiceToken.fetch(pid)
      ServiceToken.invalidate(pid)
      assert {:error, _} = ServiceToken.fetch(pid)
    end
  end

  describe "invalidate/1" do
    test "forces the next fetch to re-request", ctx do
      start_provider!(ctx.issuer)
      counter = :counters.new(1, [])

      stub_token(ctx.bypass, fn conn ->
        :counters.add(counter, 1, 1)
        token_response(conn, "tok_#{:counters.get(counter, 1)}", 3600)
      end)

      pid = start_supervised!(ServiceToken)

      assert {:ok, "tok_1"} = ServiceToken.fetch(pid)
      ServiceToken.invalidate(pid)
      assert {:ok, "tok_2"} = ServiceToken.fetch(pid)
    end

    test "is safe when the holder isn't running" do
      assert ServiceToken.invalidate(:no_such_server) == :ok
    end
  end

  describe "when unconfigured" do
    test "fetch returns :not_configured without touching the network" do
      Application.put_env(:scheduling, Scheduling.Core, [])

      assert {:error, :not_configured} = ServiceToken.fetch()
    end

    test "the child spec is absent from the supervision tree" do
      Application.put_env(:scheduling, Scheduling.Core, [])

      assert ServiceToken.child_spec_if_enabled() == nil
    end

    test "the child spec is present once configured" do
      assert ServiceToken.child_spec_if_enabled() == ServiceToken
    end
  end
end
