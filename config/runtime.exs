import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/scheduling start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :scheduling, SchedulingWeb.Endpoint, server: true
end

config :scheduling, SchedulingWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Intake-form-system compliance gate. When `api_key` is set, the accept flow
# checks that every form type required by the queue entry's diagnosis has a
# completed-and-not-flagged response on file for the patient's
# `intake_patient_id`. When `api_key` is nil (default), the check is skipped
# entirely — useful for local dev or when intake isn't reachable.
config :scheduling, Scheduling.Compliance,
  base_url: System.get_env("INTAKE_API_URL", "http://localhost:3001/api/v1"),
  api_key: System.get_env("INTAKE_API_KEY"),
  http_timeout_ms: String.to_integer(System.get_env("INTAKE_HTTP_TIMEOUT_MS", "5000"))

# ---------------------------------------------------------------------------
# OpenID Connect — browser SSO and API bearer tokens.
#
# Provider-neutral: point OIDC_ISSUER at any provider that publishes a
# discovery document. Verified against Astrum core-api
# (https://ac-core.../.well-known/openid-configuration); the role/org claim
# defaults below match it, and also cover Keycloak.
#
# Auth turns on when issuer + client id + secret are all present. Leaving them
# unset keeps a local checkout usable without an IdP, exactly like the intake
# compliance gate above.
#
# Unlike that gate, though, unconfigured auth fails OPEN — every screen and all
# 41 API endpoints become public. So the :prod block below refuses to boot
# without it unless AUTH_DISABLED=true says so on purpose.
# ---------------------------------------------------------------------------
comma_list = fn var, default ->
  var
  |> System.get_env(default)
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end

config :scheduling, Scheduling.Auth,
  issuer: System.get_env("OIDC_ISSUER"),
  client_id: System.get_env("OIDC_CLIENT_ID"),
  client_secret: System.get_env("OIDC_CLIENT_SECRET"),
  # Extra `aud` values accepted on API access tokens. A provider does not
  # necessarily name us in the `aud` of a token minted for another client, so
  # a token from the check-in bridge may carry "scheduling-api" instead.
  trusted_audiences: comma_list.("OIDC_API_AUDIENCES", ""),
  # Pinned rather than read from the token header — see Scheduling.Auth.Tokens.
  signing_algs: comma_list.("OIDC_SIGNING_ALGS", "RS256"),
  # Dotted claim paths searched for roles; every one present is unioned.
  # `<client_id>` is substituted with OIDC_CLIENT_ID.
  role_claims:
    comma_list.(
      "OIDC_ROLE_CLAIMS",
      "astrum_roles,roles,realm_access.roles,resource_access.<client_id>.roles"
    ),
  # Fields merged over the provider's discovery document. Astrum core-api omits
  # `subject_types_supported`, which OIDC Discovery marks REQUIRED and oidcc
  # enforces — without this the provider worker crash-loops at boot. Set
  # OIDC_DISCOVERY_OVERRIDES={} once the provider publishes the field.
  discovery_overrides:
    "OIDC_DISCOVERY_OVERRIDES"
    |> System.get_env(~s({"subject_types_supported":["public"]}))
    |> Jason.decode!(),
  # The one organisation this deployment serves. The provider is multi-tenant;
  # this app is not. A token from any other org is refused on both surfaces
  # even when its roles would permit the call. Unset disables the check.
  expected_org_id: System.get_env("ASTRUM_ORG_ID"),
  org_claim: System.get_env("OIDC_ORG_CLAIM", "astrum_org"),
  org_id_claim: System.get_env("OIDC_ORG_ID_CLAIM", "astrum_org_id"),
  tenant_claim: System.get_env("OIDC_TENANT_CLAIM", "astrum_tenant"),
  session_ttl_seconds: String.to_integer(System.get_env("AUTH_SESSION_TTL_SECONDS", "28800"))

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  # Fail-closed on configuration, not on requests: a release that boots with
  # auth silently off would serve PHI to anyone who found the hostname. Opting
  # out is possible but must be deliberate and is announced at boot.
  cond do
    Scheduling.Auth.enabled?() ->
      :ok

    System.get_env("AUTH_DISABLED") == "true" ->
      IO.warn("""
      AUTH_DISABLED=true — running with NO authentication.

      Every LiveView screen and all /api/v1 endpoints are public, including
      patient data. Only acceptable when something else (a private network, an
      authenticating reverse proxy) is enforcing access control.
      """)

    true ->
      raise """
      Authentication is not configured.

      Set OIDC_ISSUER, OIDC_CLIENT_ID and OIDC_CLIENT_SECRET, e.g.

          OIDC_ISSUER=https://ac-core.45.59.71.47.nip.io
          OIDC_CLIENT_ID=scheduling
          OIDC_CLIENT_SECRET=...

      To run without authentication on purpose, set AUTH_DISABLED=true.
      """
  end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :scheduling, Scheduling.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :scheduling, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :scheduling, SchedulingWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :scheduling, SchedulingWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :scheduling, SchedulingWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :scheduling, Scheduling.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
