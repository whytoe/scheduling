# Authentication & Authorization

Scheduling authenticates both of its inbound surfaces against one OpenID
Connect realm, and holds a token of its own for calling out:

- **Browser SSO** — operators sign in to the LiveView UI with the
  authorization-code flow (PKCE).
- **API bearer tokens** — the intake bridge, the check-in / queueing app and
  any other integrator call `/api/v1` with an access token from the
  client-credentials grant.
- **Outbound** — scheduling is also an OAuth *client*, holding its own
  client-credentials token to read ac-core's patient and location registry.
  See "Scheduling as an OAuth client" below.

Provider-neutral: anything that publishes a discovery document and a JWKS
works. The deployment target is **Astrum core-api**
(`https://ac-core.45.59.71.47.nip.io`), whose discovery document this
implementation was checked against; Keycloak is covered by the same defaults.

The only place a provider's individuality shows through is *where it puts
roles and tenancy in the token*, and that is configuration, not code.

What this app may *hold* once a caller is through the door is a separate
question, answered in **`data-boundary.md`**: PII yes, health data no.

Implementation: `Scheduling.Auth` and friends, `SchedulingWeb.Plugs.ApiAuth`,
`SchedulingWeb.Plugs.BrowserAuth`, `SchedulingWeb.AuthController`,
`SchedulingWeb.AuthHooks`; outbound in `Scheduling.Auth.ServiceToken` and
`Scheduling.Core`.

## Configuration

| Env var                    | Required | Default   | Purpose                                              |
|----------------------------|----------|-----------|------------------------------------------------------|
| `OIDC_ISSUER`              | yes      | —         | e.g. `https://ac-core.45.59.71.47.nip.io`             |
| `OIDC_CLIENT_ID`           | yes      | —         | This app's OAuth client, e.g. `scheduling`            |
| `OIDC_CLIENT_SECRET`       | yes      | —         | That client's secret                                  |
| `OIDC_API_AUDIENCES`       | no       | —         | Extra comma-separated `aud` values accepted on API tokens |
| `OIDC_SIGNING_ALGS`        | no       | `RS256`   | Comma-separated JWS algorithms accepted on access tokens |
| `OIDC_ROLE_CLAIMS`         | no       | see below | Comma-separated dotted claim paths searched for roles |
| `OIDC_ORG_CLAIM`           | no       | `astrum_org`    | Claim naming the organisation                   |
| `OIDC_ORG_ID_CLAIM`        | no       | `astrum_org_id` | Claim naming the organisation id                |
| `OIDC_TENANT_CLAIM`        | no       | `astrum_tenant` | Claim naming the tenant                         |
| `OIDC_DISCOVERY_OVERRIDES` | no       | `{"subject_types_supported":["public"]}` | JSON merged over the discovery document |
| `SCHEDULING_TENANCY_ID`    | no       | —         | Restricts this deployment to one tenant (see below)   |
| `OIDC_TENANCY_CLAIM`       | no       | `astrum_org_id` | Which claim carries the tenancy id            |
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

OIDC standardises `sub`, `email` and `exp` — it says nothing about roles, so
every provider invents a placement. `OIDC_ROLE_CLAIMS` is a list of dotted
claim paths; **every one present on the token is unioned**. The default covers
the shapes we have met, so both Astrum and Keycloak work unconfigured:

```
astrum_roles                        # Astrum core-api
roles                               # the plain case
realm_access.roles                  # Keycloak realm roles
resource_access.<client_id>.roles   # Keycloak client roles
```

`<client_id>` is substituted with `OIDC_CLIENT_ID`. Role comparison is
case-insensitive.

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
rules the matcher routes by, and `diagnoses.required_compliance_refs` in particular
decides which intake forms gate an assignment. A change there silently
re-routes every future patient. That is a different kind of act from accepting
the person in front of you, so it takes a different role.

## One tenant per deployment

ac-core nests **organization → practice → location**, and every `/v1` read is
"scoped to the caller's practice[s]". A practice is therefore the level that
matches how the data is actually partitioned, and a scheduling deployment
serves one.

Set `SCHEDULING_TENANCY_ID` and a token whose id does not match is refused —
403 `forbidden` on the API, and the "not permitted" page at browser sign-in.
Leave it unset and the check is skipped, matching how the rest of the auth
layer behaves unconfigured.

### Which claim carries it is not yet confirmed

ac-core's `claims_supported` advertises `astrum_org`, `astrum_org_id`,
`astrum_tenant` and `astrum_location` — **nothing named for a practice**. The
vendored spec (`ac-core-swagger.json`) does not settle it either: its only
`roles` reference is an untyped array on `POST /staff/provision`.

So the claim is configuration. `OIDC_TENANCY_CLAIM` defaults to
`astrum_org_id` — the one claim we have confirmed ac-core sends — and points
anywhere:

```sh
OIDC_TENANCY_CLAIM=astrum_tenant     # if the practice arrives as the tenant
SCHEDULING_TENANCY_ID=northside
```

**Confirm this against a real token before enabling it.** The failure mode is
not subtle but it is total: name a claim the provider does not send and
*everyone* is refused, not just outsiders. That is deliberate — a tenancy check
that fails open is not a tenancy check — but it means a typo locks out the
deployment. `test/scheduling_web/plugs/tenancy_scope_test.exs` pins that
behaviour so it stays a known quantity.

### It is an authentication boundary, not a data one

`SCHEDULING_TENANCY_ID` keeps other tenants *out*. It does not partition data
within a deployment: no query filters by tenant. If one deployment ever needs
to serve several practices, that is a schema change (tenant id on patients,
visits, queue entries, offices) plus scoping every query and PubSub topic.

## Scheduling as an OAuth *client*

Everything above is scheduling as a **resource server** — validating tokens
other parties present. It is also a **client**: it calls ac-core's `/v1` API
for the patient and location registry, and needs its own token to do it.

`Scheduling.Auth.ServiceToken` obtains one via the client-credentials grant
(`Oidcc.client_credentials_token/4`, reusing the same discovery worker), caches
it, and refreshes a minute before expiry. `Scheduling.Core.Client` uses it.

**Separate credentials from the browser SSO client:**

| | Identifies | Scopes |
|---|---|---|
| `OIDC_CLIENT_ID` | the web app, to end users | `openid profile email roles` |
| `CORE_CLIENT_ID` | scheduling-as-a-service, to ac-core | `core:patients:read core:organizations:read` |

Two clients rather than one so the browser client's secret is not also a key to
the patient registry, and so the read scopes can be granted narrowly.
`core:patients:write` is deliberately absent — scheduling projects patient
data, it does not author it.

Three behaviours worth knowing:

- **A failed exchange is never cached** and never clobbers a still-valid token.
  A refresh failure should not turn a working cache into an outage.
- **The exchange traps exits.** It reaches the shared provider worker via
  `GenServer.call`, so a worker that is down or backing off after failed
  discovery would otherwise take the token holder with it — an IdP blip
  becoming a supervision cascade.
- **A 401 from ac-core invalidates the cached token**, so the next call
  re-fetches rather than replaying a credential ac-core has stopped honouring.

What the client is allowed to do with what it reads is a separate constraint —
see `data-boundary.md` §"Reading from ac-core".

## Back-channel logout

Astrum advertises `backchannel_logout_supported: true`, so it can tell us when
a session ends elsewhere — a different device, or an admin terminating it.
Without a receiver, such a session would stay live here until the 8h deadline.

`POST /auth/backchannel-logout` accepts a logout token (OpenID Connect
Back-Channel Logout 1.0). It is public and CSRF-exempt because the IdP calls it
server-to-server with no session; the token's signature is the authentication.
Validation goes through the same `Oidcc.Token.validate_jwt/3` path as every
other token, plus the spec's extra rules: the `events` claim must contain
`http://schemas.openid.net/event/backchannel-logout`, and a `nonce` must be
absent (it belongs only on an ID token).

Revocation is a `revoked_sessions` row — Postgres rather than ETS because
`DNSCluster` is configured and revocation has to hold across nodes.
`BrowserAuth.scope_from_session/1` checks it, which is the single choke point
both the plug pipeline and the LiveView hooks already share, so a revoked
session behaves exactly like an expired one. An hourly sweeper drops rows past
their expiry.

**Scope**: §2.4 lets a token carry `sub`, `sid`, or both. When `sid` is
present it wins — that names one session, and revoking the subject too would
sign an operator out at the nurses' station because they logged out on their
phone. Only a token with no `sid` means "everywhere".

**Known limitation**: a `sid`-only token (no `sub`) is spec-legal but rejected,
because `oidcc` requires `sub` on every JWT and fails before our checks run.
Accepting one would mean hand-composing a JWT validator for a public,
unauthenticated endpoint, which is a worse trade. ac-core sends `sub` on every
other token type, so this likely never bites, and the failure is a loud 400
with a logged `missing_claim` rather than a silent hole.

## Provider setup

### Astrum core-api (the deployment target)

Discovery: `https://ac-core.45.59.71.47.nip.io/.well-known/openid-configuration`

What it advertises, and what we use:

| | |
|---|---|
| `authorization_endpoint` | `/authorize` |
| `token_endpoint` | `/oauth/token` (`client_secret_basic`, `client_secret_post`) |
| `jwks_uri` | `/oauth/jwks` — one RS256 key today |
| `end_session_endpoint` | `/end-session` — used for RP-initiated logout |
| `grant_types` | `authorization_code`, `client_credentials`, `refresh_token` |
| `code_challenge_methods` | `S256` — PKCE, which we always send |
| roles claim | `astrum_roles` |
| tenancy claims | `astrum_org`, `astrum_org_id`, `astrum_tenant`, `astrum_location` |
| other claims | `sub`, `email`, `email_verified`, `name`, `sid`, `auth_time`, `nonce`, `astrum_apps` |

### ⚠ Its discovery document is missing a required field

`ac-core`'s document omits **`subject_types_supported`**, which OIDC Discovery
1.0 §3 marks REQUIRED. `oidcc` enforces the required set, so without a
workaround the provider worker **crash-loops at boot** and every request
returns `503 provider_unavailable` — the app never serves a page.

`OIDC_DISCOVERY_OVERRIDES` supplies it, and defaults to exactly that:

```json
{"subject_types_supported": ["public"]}
```

Nothing in this app reads the field — it describes whether the provider issues
pairwise `sub` values, which matters only to a client correlating subjects
across relying parties — so filling it in is inert beyond satisfying
validation.

**This is a workaround, not a feature.** The right fix is for `ac-core` to
publish the field; set `OIDC_DISCOVERY_OVERRIDES={}` once it does.
`test/scheduling/auth/provider_test.exs` asserts both that the override works
and that it is still load-bearing, so the day the provider is fixed the test
tells you the override can go.

Register two kinds of client:

1. **The web client** — `scheduling`, confidential, authorization-code flow.
   Redirect URI `https://<host>/auth/callback`, post-logout redirect URI
   `https://<host>/auth/signed_out`.
2. **One service client per integration** — `intake-bridge`, `checkin-app`, …
   client-credentials only. One each, so revoking one does not affect the
   others and the audit log names which system acted.

Each needs the `scheduling` app's roles in `astrum_roles` (see the role table
above), and each service client's tokens must carry an `aud` this app accepts
— either `scheduling` itself, or a value listed in `OIDC_API_AUDIENCES`.

> **Open, needs a real token to settle.** The values Astrum actually puts in
> `astrum_roles` have not been observed — the `/docs` endpoint is 401 and no
> token was available while this was written. If they are platform-wide roles
> (`provider`, `staff`, …) rather than this app's four, map them with
> `OIDC_ROLE_CLAIMS` pointed at a scheduling-specific claim, or have the
> provider issue `admin`/`operator`/`viewer`/`service` for this client.
> Likewise `astrum_apps` looks like an app-entitlement list; if it is, gating
> sign-in on it containing `scheduling` would be worth adding.

### Keycloak

Also supported by the defaults, unconfigured.

- Client `scheduling`, client authentication **on**, standard flow on, direct
  access grants off. Redirect `https://<host>/auth/callback`, post-logout
  `https://<host>/auth/signed_out`. Setting *Advanced → PKCE method* to `S256`
  makes Keycloak require what we already send.
- Realm roles `admin` / `operator` / `viewer`, assigned to users or groups.
  Client roles on the `scheduling` client work too — both are read.
- One service client per integration: client authentication on, standard flow
  **off**, **service accounts on**, then assign it the `service` role.

Keycloak puts `realm_access` / `resource_access` on the **access token**, not
the ID token, by default. The app handles this — it validates the access token
too and takes roles from there when the ID token has none — so no mapper change
is needed.

## Calling the API

```sh
TOKEN=$(curl -s -X POST "$OIDC_ISSUER/oauth/token" \
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

A service account's `sub` is an opaque uuid that names nothing a human
recognises, so services are attributed by client id: an operator reading the
timeline sees `service:intake-bridge`, not `service:b3f1e0c2-…`.

**Telling the two apart** is provider-neutral, because the vendor conventions
disagree. Keycloak marks client-credentials tokens with
`preferred_username: "service-account-<client>"`; Astrum sends no
`preferred_username` at all. So the rule is the one OIDC implies: *a token with
no end-user identity on it is a service token*. `email`, `sid` and
`preferred_username` each describe a human who authenticated, and a
client-credentials grant has none of them. Keycloak's convention is honoured
too, since Keycloak does send a username on service tokens.

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

**Session lifetime is ours, not the ID token's.** ID tokens typically expire in
about five minutes. Honouring that literally would bounce an operator through
the IdP mid-shift, repeatedly, for no security gain — what actually governs
whether they must retype a password is the Keycloak SSO session. Our 8h
deadline is there so a stolen session cookie stops working and role changes
land within the day.

**Signing algorithms are pinned.** An access token is not an ID token: OIDC
does not specify its shape, so the discovery document does not say how it is
signed. `OIDC_SIGNING_ALGS` (default `RS256`) is what the app accepts,
rather than trusting the token header's `alg`. That is what makes `alg: none`
and RS256/HS256 confusion inapplicable rather than merely unlikely.

**JWKS rotation is handled.** `Oidcc.ProviderConfiguration.Worker` caches the
discovery document and JWKS and re-fetches on an unrecognised `kid`, so
rotating signing keys does not reject valid traffic.

**A JSON `null` claim is not `nil`.** `oidcc` decodes JSON `null` to the atom
`:null`. A provider that sends `"email": null` rather than omitting the key
therefore produces a value `is_nil/1` does not catch — which would classify
every such service token as a human and store `:null` as somebody's email
address. Claim reads go through a normaliser that maps `nil`, `:null` and `""`
alike to absent.

**`live_session` is the LiveView boundary.** LiveView skips re-running
`on_mount` hooks only when navigating *within* one `live_session`. The operator
screens and the catalog screens are separate sessions, so a mounted socket
cannot be carried by live navigation into a route that requires more than it
mounted under.

## What is not covered

- **No token revocation check.** A token stays valid until `exp` even if the
  provider's session is ended. Keeping access-token lifetimes short is the
  mitigation. Astrum exposes `/oauth/introspect`; calling it per request would
  close the window at the cost of a round-trip per call.
- **No rate limiting.** Tracked as `sc-c41`.
- **No multi-tenant data scoping.** `SCHEDULING_TENANCY_ID` keeps other tenants
  *out*; it does not partition data within a deployment. No query filters by
  tenant. See "One tenant per deployment" above.
- **`astrum_location` is ignored.** If offices map onto it, that is the natural
  key for per-location scoping.
- **`astrum_apps` is ignored.** It looks like an app-entitlement list; gating
  sign-in on it containing `scheduling` is Phase 2b, pending confirmation
  against a real token.
- **Dev routes** (`/dev/dashboard`, `/dev/mailbox`) are unauthenticated. They
  are compiled out unless `:dev_routes` is set, which is dev and test only.

## Local development

Leave the `OIDC_*` variables unset and the app runs with no auth — every
screen open, every endpoint open, `current_scope` nil. This is what the
quickstart in `integrations.md` assumes.

To exercise the real thing locally, point at the deployed provider:

```sh
export OIDC_ISSUER=https://ac-core.45.59.71.47.nip.io
export OIDC_CLIENT_ID=scheduling
export OIDC_CLIENT_SECRET=...
mix phx.server
```

The redirect URI registered for the client must include your local
`http://localhost:4000/auth/callback` for the browser flow to complete.

The test suite does not need any of this: `Scheduling.OidcProvider`
(`test/support/oidc_provider.ex`) stands up a fake provider on Bypass with a
generated RSA key and mints real signed tokens against it, so the tests run the
actual `oidcc` validation path. It mints **both** claim shapes — pass
`shape: :astrum` (the default) or `shape: :keycloak` — because the point of
`OIDC_ROLE_CLAIMS` is that either works unconfigured.
