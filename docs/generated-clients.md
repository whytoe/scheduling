# Generated API clients

Scheduling publishes an OpenAPI 3 spec; you should **generate** your client from
it rather than hand-roll one. This page names a toolchain per language, gives a
copy-pasteable command for each, and explains how to stay compatible as the API
evolves.

## Where the spec lives

| What | URL |
|---|---|
| OpenAPI JSON | `GET /api/openapi.json` |
| Swagger UI (browse + try) | `GET /api/swagger` |

The spec's `info.version` is the running app version, so the document you
generate from always matches the deployment you fetched it from. Save a copy
alongside your generated code so a regeneration is a reviewable diff:

```sh
curl -fsS https://<host>/api/openapi.json -o openapi.json
```

## Toolchains by language

Pick one generator and pin its version — a generator upgrade can reshape the
output as much as an API change can.

### TypeScript / JavaScript — `openapi-typescript` (types) + `openapi-fetch`

Lightweight: types from the spec, a tiny typed fetch wrapper, no runtime codegen.

```sh
npx openapi-typescript openapi.json -o src/scheduling-api.d.ts
# then use openapi-fetch, which is typed by that file:
npm i openapi-fetch
```

```ts
import createClient from "openapi-fetch";
import type { paths } from "./scheduling-api";
const api = createClient<paths>({ baseUrl: "https://<host>" });
const { data } = await api.GET("/api/v1/queue_entries", { params: { query: { status: "waiting" } } });
```

For a heavier, class-based SDK instead, use `openapi-generator` with
`-g typescript-fetch` (see below).

### Go — `oapi-codegen`

```sh
go install github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@latest
oapi-codegen -generate types,client -package scheduling openapi.json > scheduling.gen.go
```

### Python — `openapi-python-client`

```sh
pipx run openapi-python-client generate --path openapi.json
```

(`bravado` also works if you prefer a dynamic, spec-driven client with no
codegen step.)

### Anything else — `openapi-generator` (multi-language)

Covers Java, C#, Ruby, PHP, Rust, Kotlin, Swift, and ~50 more.

```sh
npx @openapitools/openapi-generator-cli generate \
  -i openapi.json -g <generator> -o ./client
# list generators: npx @openapitools/openapi-generator-cli list
```

## Authenticating the generated client

Every `/api/v1/*` call takes a bearer token — an OAuth **client-credentials**
access token from the same ac-core realm the UI uses (see `docs/auth.md` and
`docs/integrations.md`). Generated clients expose a per-request or per-client
header hook; set:

```
Authorization: Bearer <access_token>
```

The token is opaque and short-lived; fetch a fresh one from the issuer's
`/oauth/token` and refresh on `401`. Read endpoints need any recognised role;
write endpoints need `operator`/`service`/`admin`.

## Staying compatible

The API is **additive within a version**: new optional fields and new endpoints
may appear without a version bump; existing fields are not removed or retyped
without one. Practical rules for a generated client:

| Change on our side | What your client should do |
|---|---|
| New optional response field | Ignore unknown fields — do not fail closed on them |
| New endpoint | Regenerate to pick it up; nothing breaks if you don't |
| New required **request** field | Announced; regenerate before it ships |
| Field removed / retyped | Only on a major version; announced |

Regenerate on a schedule (or in CI) by re-fetching `/api/openapi.json` and
diffing — a no-op diff means nothing relevant to you changed.

### Pagination & idempotency (client-side)

Two cross-cutting behaviours the generated types describe but your code must
honour (see `docs/integrations.md`):

- **Pagination** — list endpoints return a raw array plus an `X-Next-Cursor`
  response header; pass it back as `?after=<cursor>` for the next page. Treat
  the cursor as opaque.
- **Idempotency** — send an `Idempotency-Key` header on writes and reuse it on
  retries so a repeated request happens once.

## Optional: a shipped client

We do not currently publish a pre-generated client in a sibling repo. If demand
warrants it, the first candidate is a TypeScript package (the check-in and
queueing apps are the primary consumers); it would be generated from this same
spec in CI so it never drifts from the deployment.
