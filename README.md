# Scheduling

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? See [`DEPLOYMENT.md`](DEPLOYMENT.md).

## Documentation

| | |
|---|---|
| [`docs/data-boundary.md`](docs/data-boundary.md) | **Read this before adding a field.** Scheduling carries PII, not health data — what that means per table, and the three egress paths that enforce it. |
| [`docs/auth.md`](docs/auth.md) | OIDC setup: browser SSO, API bearer tokens, roles, tenancy scoping, back-channel logout, and the outbound client for ac-core. |
| [`docs/integrations.md`](docs/integrations.md) | The API we expose, the intake-form system we consume, audit logs, outbound webhooks. |
| [`docs/integration-contracts.md`](docs/integration-contracts.md) | Decision record for the check-in / forms contracts, reconciled against the real ac-core spec. |
| [`docs/ac-core-swagger.json`](docs/ac-core-swagger.json) | Vendored OpenAPI document for the Avenue D Core API. |
| [`docs/design-system.md`](docs/design-system.md) | Theme tokens, component patterns, accessibility guarantees. |
| [`DEPLOYMENT.md`](DEPLOYMENT.md) | Environment variables, Postgres requirements, health probe. |

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
