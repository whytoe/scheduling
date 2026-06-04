import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :scheduling, Scheduling.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "scheduling_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :scheduling, SchedulingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "dUH5n3/TNUBwKPM5+qdZ7f0fvhdyKWLPZgptcurJwzjMdt+swqTQl2qbUf9x9yXa",
  server: false

# In test we don't send emails
config :scheduling, Scheduling.Mailer, adapter: Swoosh.Adapters.Test

# Disable outbound webhooks by default in test so unrelated tests don't fire
# off background HTTP requests. The webhook tests turn this on per-test.
config :scheduling, :webhooks_enabled, false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
