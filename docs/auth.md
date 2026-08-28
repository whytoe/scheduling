# Authentication & Authorization

Scheduling authenticates both of its surfaces against one OpenID Connect
realm:

- **Browser SSO** — operators sign in to the LiveView UI with the
  authorization-code flow (PKCE).
- **API bearer tokens** — the intake bridge, the check-in / queueing app and
  any other integrator call `/api/v1` with an access token from the
  client-credentials grant.

Written against Keycloak, but nothing here is Keycloak-specific beyond where
roles live in the token. Any OIDC provider that publishes a discovery document
and a JWKS will work.

Implementation: `Scheduling.Auth` and friends, `SchedulingWeb.Plugs.ApiAuth`,
`SchedulingWeb.Plugs.BrowserAuth`, `SchedulingWeb.AuthController`,
`SchedulingWeb.AuthHooks`.

## Configuration

| Env var                    | Required | Default   | Purpose                                              |
|----------------------------|----------|-----------|------------------------------------------------------|
| `KEYCLOAK_ISSUER`          | yes      | —         | e.g. `https://sso.example.org/realms/clinic`          |
| `KEYCLOAK_CLIENT_ID`       | yes      | —         | This app's OAuth client, e.g. `scheduling`            |
| `KEYCLOAK_CLIENT_SECRET`   | yes      | —         | That client's secret                                  |
| `KEYCLOAK_API_AUDIENCES`   | no       | —         | Extra comma-separated `aud` values accepted on API tokens |
| `KEYCLOAK_SIGNING_ALGS`    | no       | `RS256`   | Comma-separated JWS algorithms accepted on access tokens |
| `AUTH_SESSION_TTL_SECONDS` | no       | `28800`   | Browser session lifetime (8h)                         |
| `AUTH_DISABLED`            | no       | unset     | `true` permits a `:prod` boot with no auth            |

Auth turns on when the three required variables are all set. With any of them
missing it is **off**, and every screen and endpoint is public — which is fine
for a local checkout and catastrophic in production. So `config/runtime.exs`
refuses to boot a `:prod` release with auth unconfigured unless
`AUTH_DISABLED=true` says so deliberately, which logs a warning at startup.

## Roles

Roles come from the token. There is no local users table and no provisioning
step — a role granted in the realm takes effect at the operator's next sign-in
(or within `AUTH_SESSION_TTL_SECONDS` for an existing session).

Both Keycloak placements are read and unioned:

```
realm_access.roles                        # realm roles
resource_access.<KEYCLOAK_CLIENT_ID>.roles  # client roles for this app
```

Four roles are recognised. Anything else on the token is carried through but
grants nothing.

| Role       | UI                                    | API                                            |
|------------|---------------------------------------|------------------------------------------------|
| `viewer`   | Board, Queue, Decisions, Visits, Visit events | `GET` everything except webhook subscriptions |
| `operator` | the above                             | the above, plus patient-flow writes            |
| `service`  | (not a UI role)                       | same as `operator` — the role for integrations |
| `admin`    | the above, plus Offices, Capabilities, Diagnoses | everything, including catalog CRUD and webhook subscriptions |

`admin` satisfies every other role, so an admin needs only that one.

A token that authenticates but carries no recognised role is **rejected with
403**, not silently shown an empty board. In the UI that lands on a page saying
to ask an administrator for access.

### Why the catalog is admin-only

Offices, capabilities and diagnoses are not per-patient records — they are the
rules the matcher routes by, and `diagnoses.required_form_types` in particular
decides which intake forms gate an assignment. A change there silently
re-routes every future patient. That is a different kind of act from accepting
the person in front of you, so it takes a different role.

## Keycloak realm setup

### 1. The web client

Clients → Create client:

- Client ID: `scheduling`
- Client authentication: **On** (confidential — the app holds a secret)
- Standard flow: **On**; Direct access grants: **Off**
- Valid redirect URIs: `https://scheduling.example.com/auth/callback`
- Valid post logout redirect URIs: `https://scheduling.example.com/auth/signed_out`
- Web origins: `https://scheduling.example.com`

Copy the secret from the Credentials tab into `KEYCLOAK_CLIENT_SECRET`.

PKCE is sent by the app on every authorization request. Setting *Advanced →
Proof Key for Code Exchange Code Challenge Method* to `S256` makes Keycloak
require it, which is worth doing — it closes the flow to a client that omits
it.

### 2. Roles

Realm roles → Create role, once each for `admin`, `operator`, `viewer`. Assign
them to users or (better) to groups.

Client roles on the `scheduling` client work equally well if you prefer to keep
them scoped to this app; the token is read for both.

> **Note.** Keycloak puts `realm_access` / `resource_access` on the **access
> token** by default, not the ID token. The app handles this — it validates the
> access token as well and takes roles from there when the ID token has none —
> so no mapper change is needed. If you would rather have roles on the ID
> token, enable *Add to ID token* on the realm-roles mapper; that path works too.

### 3. A service client per integration

One client per integrating system, so revoking one does not affect the others,
and so the audit log names which system acted.

Clients → Create client:

- Client ID: `intake-bridge` (or `checkin-app`, etc.)
- Client authentication: **On**
- Standard flow: **Off**; **Service accounts roles: On**
- Everything else off

Then Service account roles → Assign role → `service`.

If the resulting token's `aud` does not include `scheduling`, either add an
audience mapper on the service client (Client scopes → dedicated →
Add mapper → Audience → Included Client Audience: `scheduling`), or list the
audience it does carry in `KEYCLOAK_API_AUDIENCES`.

## Calling the API

```sh
TOKEN=$(curl -s -X POST \
  "$KEYCLOAK_ISSUER/protocol/openid-connect/token" \
  -d grant_type=client_credentials \
  -d client_id=intake-bridge \
  -d client_secret=... | jq -r .access_token)

curl -s https://scheduling.example.com/api/v1/board \
  -H "Authorization: Bearer $TOKEN"
```

Tokens are short-lived. Fetch a new one when you get a 401 with
`error.code == "token_expired"`; do not cache one past its `expires_in`.

### Error codes

All auth failures use the standard envelope
(`{"error": {"code", "message", "details"}}`):

| Status | `error.code`           | Meaning                                                     |
|--------|------------------------|-------------------------------------------------------------|
| 401    | `unauthorized`         | No `Authorization: Bearer` header, or it was malformed      |
| 401    | `invalid_token`        | Bad signature, wrong issuer, wrong audience, not a JWT      |
| 401    | `token_expired`        | Past `exp` — get a new token                                |
| 403    | `forbidden`            | Valid token, insufficient role. `details` names required vs granted |
| 503    | `provider_unavailable` | The IdP could not be reached to verify the token            |

401s carry `WWW-Authenticate: Bearer ...` per RFC 6750.

`invalid_token` is deliberately one code for several distinct failures.
Telling an unauthenticated caller *which* check failed hands them an oracle;
the specific reason is in the server log.

## Actor attribution

Mutating endpoints record `(actor_type, actor_id)` on the resulting
`visit_event`. These now come from the token, and `actor_type` / `actor_id` in
the request body are **ignored**:

| Token kind | `actor_type` | `actor_id`                                    |
|------------|--------------|-----------------------------------------------|
| User       | `user`       | the `sub` claim                               |
| Service    | `service`    | the `azp` claim — the OAuth client id         |

A service account's `sub` is an opaque realm uuid that names nothing a human
recognises, so services are attributed by client id: an operator reading the
timeline sees `service:intake-bridge`, not
`service:b3f1e0c2-…`. Keycloak marks client-credentials tokens by setting
`preferred_username` to `service-account-<client-id>`, which is how the two are
told apart.

This is the change that makes the audit log trustworthy. Previously the actor
was whatever the caller put in the request body, so any client could attribute
an action to any person.

## Design notes

**No tokens in the session cookie.** The browser session holds only a compact
identity map — subject, name, email, roles, expiry. The session cookie is
signed but readable, and capped at 4KB, which a Keycloak access + refresh + ID
token triple can exceed on its own. A cookie that never holds a token has no
token to leak.

The consequence is that there is no refresh token to refresh with. When the
session expires the operator is bounced through `/auth/login`, which the IdP
answers silently from its own SSO cookie if the Keycloak session is still
alive. They see a redirect, not a login form.

**Session lifetime is ours, not the ID token's.** Keycloak ID tokens expire in
about five minutes. Honouring that literally would bounce an operator through
the IdP mid-shift, repeatedly, for no security gain — what actually governs
whether they must retype a password is the Keycloak SSO session. Our 8h
deadline is there so a stolen session cookie stops working and role changes
land within the day.

**Signing algorithms are pinned.** An access token is not an ID token: OIDC
does not specify its shape, so the discovery document does not say how it is
signed. `KEYCLOAK_SIGNING_ALGS` (default `RS256`) is what the app accepts,
rather than trusting the token header's `alg`. That is what makes `alg: none`
and RS256/HS256 confusion inapplicable rather than merely unlikely.

**JWKS rotation is handled.** `Oidcc.ProviderConfiguration.Worker` caches the
discovery document and JWKS and re-fetches on an unrecognised `kid`, so
rotating realm keys does not reject valid traffic.

**`live_session` is the LiveView boundary.** LiveView skips re-running
`on_mount` hooks only when navigating *within* one `live_session`. The operator
screens and the catalog screens are separate sessions, so a mounted socket
cannot be carried by live navigation into a route that requires more than it
mounted under.

## What is not covered

- **No token revocation check.** A token stays valid until `exp` even if the
  realm session is ended. Keeping access-token lifetimes short (Keycloak's
  5-minute default) is the mitigation. Introspection on every request would
  close the window at the cost of an IdP round-trip per call.
- **No rate limiting.** Tracked as `sc-c41`.
- **No per-office or per-tenant scoping.** Any authorized role sees every
  patient in the deployment.
- **Dev routes** (`/dev/dashboard`, `/dev/mailbox`) are unauthenticated. They
  are compiled out unless `:dev_routes` is set, which is dev and test only.

## Local development

Leave the `KEYCLOAK_*` variables unset and the app runs with no auth — every
screen open, every endpoint open, `current_scope` nil. This is what the
quickstart in `integrations.md` assumes.

To exercise the real thing locally, run Keycloak and point at it:

```sh
docker run -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  quay.io/keycloak/keycloak:26.0 start-dev

export KEYCLOAK_ISSUER=http://localhost:8080/realms/master
export KEYCLOAK_CLIENT_ID=scheduling
export KEYCLOAK_CLIENT_SECRET=...
mix phx.server
```

The test suite does not need any of this: `Scheduling.OidcProvider`
(`test/support/oidc_provider.ex`) stands up a fake provider on Bypass with a
generated RSA key and mints real signed tokens against it, so the tests run the
actual `oidcc` validation path.
