defmodule Scheduling.Auth.ProviderTest do
  @moduledoc """
  Discovery-document handling.

  The deployment target (Astrum core-api) publishes a document missing
  `subject_types_supported`, which OIDC Discovery 1.0 §3 marks REQUIRED and
  `oidcc` enforces. Without the override this fails at *boot* — the provider
  worker crash-loops and every request returns 503 — so it is worth a test
  that fails loudly rather than a comment that can rot.
  """
  use ExUnit.Case, async: false

  alias Scheduling.Auth
  alias Scheduling.Auth.Provider

  setup do
    bypass = Bypass.open()
    issuer = "http://localhost:#{bypass.port}"
    on_exit(fn -> Application.delete_env(:scheduling, Scheduling.Auth) end)
    %{bypass: bypass, issuer: issuer}
  end

  # A document deliberately shaped like ac-core's: every field it publishes,
  # and nothing it doesn't.
  defp stub_discovery(bypass, issuer, extra) do
    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      body =
        %{
          "issuer" => issuer,
          "authorization_endpoint" => issuer <> "/authorize",
          "token_endpoint" => issuer <> "/oauth/token",
          "jwks_uri" => issuer <> "/oauth/jwks",
          "end_session_endpoint" => issuer <> "/end-session",
          "response_types_supported" => ["code"],
          "grant_types_supported" => ["authorization_code", "client_credentials"],
          "id_token_signing_alg_values_supported" => ["RS256"],
          "scopes_supported" => ["openid", "profile", "email", "roles"],
          "code_challenge_methods_supported" => ["S256"],
          "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
        }
        |> Map.merge(extra)
        |> Jason.encode!()

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

  defp configure(issuer, overrides) do
    Application.put_env(:scheduling, Scheduling.Auth,
      issuer: issuer,
      client_id: "scheduling",
      client_secret: "secret",
      discovery_overrides: overrides
    )
  end

  defp worker_spec do
    opts =
      Provider.provider_configuration_opts()
      |> Map.put(:quirks, Map.put(quirks(), :allow_unsafe_http, true))

    %{
      issuer: Auth.issuer(),
      name: Auth.provider_name(),
      provider_configuration_opts: opts
    }
  end

  defp quirks, do: Map.get(Provider.provider_configuration_opts(), :quirks, %{})

  defp start_worker, do: start_supervised({Oidcc.ProviderConfiguration.Worker, worker_spec()})

  test "a document missing subject_types_supported starts with the default override",
       %{bypass: bypass, issuer: issuer} do
    stub_discovery(bypass, issuer, %{})
    configure(issuer, %{"subject_types_supported" => ["public"]})

    assert {:ok, _pid} = start_worker()
    assert {:ok, _context} = Provider.client_context()
  end

  test "the same document fails without the override — the override is load-bearing",
       %{bypass: bypass, issuer: issuer} do
    stub_discovery(bypass, issuer, %{})
    configure(issuer, %{})

    # The document is fetched in handle_continue, so start_link returns :ok and
    # the worker dies a moment later. Trapping the exit is what makes the
    # failure observable rather than a stray crash in the log.
    Process.flag(:trap_exit, true)
    {:ok, pid} = Oidcc.ProviderConfiguration.Worker.start_link(worker_spec())

    assert_receive {:EXIT, ^pid,
                    {:configuration_load_failed,
                     {:missing_config_property, :subject_types_supported}}},
                   2_000
  end

  test "a conformant document needs no override", %{bypass: bypass, issuer: issuer} do
    stub_discovery(bypass, issuer, %{"subject_types_supported" => ["pairwise"]})
    configure(issuer, %{})

    assert {:ok, _pid} = start_worker()
    assert {:ok, _context} = Provider.client_context()
  end

  test "an empty override map produces no quirks at all", %{issuer: issuer} do
    configure(issuer, %{})

    assert Provider.provider_configuration_opts() == %{}
  end
end
