# Asks for the ac-core team

Written 2026-09-09. Everything below is evidence from the live deployment, not
inference.

Scheduling authenticates users and services against ac-core and treats it as
the system of record for patients, practices and locations. Three things it
issues today stop short of what a resource server needs, and each blocks
something concrete.

None of these are things scheduling can fix on its own without duplicating a
decision that belongs in ac-core.

---

## The evidence

A client-credentials token minted by scheduling's own machine client
(`cmtnp9g4w002n01ixe5brn68r`), introspected at
`https://ac-core.45.59.71.47.nip.io/oauth/introspect`:

```json
{
  "active": true,
  "client_id": "cmtnp9g4w002n01ixe5brn68r",
  "app_id": "cmsh0zufg000301gtndzylc48",
  "app_slug": "dw-forms",
  "scope": "core:patients:read core:organizations:read",
  "practice_slugs": [],
  "exp": 1789013208,
  "iat": 1789009608,
  "token_type": "Bearer"
}
```

---

## 1. The client is bound to no practices — **blocking**

`practice_slugs` is empty, so `GET /v1/locations` returns an empty page. Reads
are scoped to the caller's practices, and this caller has none.

The effect is not an error anywhere. Scheduling's hourly location sync reports
`0 upserted, 0 deactivated, 1 page(s)` and everything looks healthy. Downstream,
per-office access control silently stops restricting anything: operators are
scoped to locations, locations are projected from ac-core, and an empty
projection means every office is unlinked and therefore visible to everyone.

**Ask:** bind the client to the practice(s) whose locations scheduling should
see.

**Also worth checking:** the client is registered under `app_slug: "dw-forms"`,
which is the intake application rather than scheduling. That may be incidental
to how it was created, or the credential may be scoped to the wrong application
entirely — we cannot tell from outside.

---

## 2. Machine tokens carry no roles or entitlement claim — **blocking**

The token has no `astrum_roles`, and no other claim describing what the caller
may do. Scheduling authorises `/api/v1` on roles, so a machine token
authenticates successfully and is then refused on every operation with 403.

That is the correct behaviour for a token that says nothing about its
authority — but it means **no service can currently call scheduling's API at
all**, including check-in and intake, which is the integration this all exists
for.

**Ask, preferred:** issue a scheduling-namespace scope alongside the existing
`core:*` ones, granted per client:

```
scheduling:read     may read the board, queue, visits
scheduling:write    may create and accept queue entries, end visits
```

Scopes rather than roles because that is the idiomatic OAuth answer for
machine-to-machine authorisation, and because ac-core already issues scopes and
already knows which clients should have them. Mapping a scheduling-namespace
scope onto scheduling's own permissions is our job and we will do it; deciding
*which clients get it* is yours, and should not be duplicated in our
configuration.

**Ask, alternative:** populate `astrum_roles` on machine tokens with the roles
the client has been granted. Equivalent for our purposes — it is the same
information, in the claim our user tokens already use.

What we would rather not do, and why we are asking instead: maintain a list of
trusted client ids on our side and grant roles from it. That works, and it puts
a second source of truth for authorisation in an environment variable — one
that will not be updated when a client is revoked in ac-core.

---

## 3. No `aud` on introspection responses — **non-blocking, but it removes a control**

RFC 7662 does not require `aud`, so this is not a defect. It does mean a
resource server cannot tell whether a token was minted *for it*.

Scheduling checks `aud` against a trusted list when the response carries one,
and accepts when it does not — because rejecting would refuse every ac-core
token. With `aud` absent the effective rule degrades to "any live token from
this realm carrying a recognised role". Combined with (2) being fixed, that
means any client granted a scheduling scope can call us, which is probably what
you intend — but there is then nothing distinguishing a token minted for
scheduling from one minted for another resource server in the same realm and
replayed at us.

**Ask:** include `aud` in the introspection response, naming the intended
resource server(s).

Lower priority than (1) and (2): if scheduling-namespace scopes land, the scope
itself carries most of the same signal.

---

## 4. `/oauth/introspect` answers unauthenticated callers — **please confirm intent**

```
$ curl -X POST https://ac-core.45.59.71.47.nip.io/oauth/introspect -d token=abc
200 {"active":false}
```

No client credentials presented. RFC 7662 §2.1 says the endpoint MUST require
authorization, because an open one is a token-status oracle.

We have **not** established whether it would return `active: true` and claims to
an unauthenticated caller holding a real token — testing that needs a live
token and we did not think it appropriate to try. Answering a flat
`active: false` to unauthenticated callers would be a defensible design.

**Ask:** confirm which it is. If real tokens are described to unauthenticated
callers, that is worth fixing regardless of anything above.

Noting one consequence for us either way: scheduling's introspection currently
authenticates with the **browser** client, which ac-core refuses the
`client_credentials` grant. If the endpoint starts enforcing client
authentication, our calls may break — we would switch to the machine client's
credentials, but would rather know before it happens than after.

---

## What we are not asking for

Nothing about token *format*. ac-core issues opaque access tokens
(`format=opaque length=68 expires_in=3600`, confirmed in production), which is
entirely legitimate — OIDC defines the shape of the ID token only. Scheduling
validates them by introspection and that works. This is only listed so nobody
spends time on it: the opacity is not a problem, the missing claims are.
