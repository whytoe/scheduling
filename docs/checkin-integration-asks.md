# Asks for the Check-in team

Written 2026-08-29 against `ac-checkin.json` ("Avenue D Pediatrics — Check-in
API" v1.0.0, 195 paths). Send this to whoever owns that service.

## The agreed flow

1. **Scheduling** owns booking — publishes schedules, availability and
   appointments into check-in.
2. **Check-in** registers the patient on arrival.
3. **Scheduling** decides which room they go to.
4. **Scheduling** owns the rules for which forms a service requires;
   **check-in** serves those forms to the patient.

Steps 1 and 3 are built or buildable on our side. **Steps 2, 3 and 4 have no
surface to land on in the external API**, so the loop cannot close yet.

Two of these are blocking. All are on the `/v1/external/*` surface, which we
reach with a core-issued client-credentials token — that part already works.

---

## 1. Request-body schemas for the external write endpoints — **blocking**

11 of the 12 `/v1/external/*` write endpoints document a response but no
request body. Only `POST /v1/external/forms/documents` has one.

```
POST  /v1/external/scheduling/appointments
PATCH /v1/external/scheduling/appointments/{externalId}
POST  /v1/external/scheduling/appointments/{externalId}/arrive
POST  /v1/external/scheduling/schedules
POST  /v1/external/scheduling/availability
PATCH /v1/external/scheduling/slots/{externalId}
POST  /v1/external/forms/submissions
PUT   /v1/external/forms/submissions/{externalId}
POST  /v1/external/forms/consents
POST  /v1/external/forms/documents/{documentId}/complete
POST  /v1/external/intake-refs
```

We generate our client from the spec rather than hand-rolling it — a recorded
decision, precisely so we do not build against guesses that drift. Without
request schemas we cannot generate anything for the write surface.

## 2. An arrival signal that identifies the patient — **blocking**

`GET /v1/external/queue` returns:

```json
{"queue": [{"id": "…", "status": "…", "queuePosition": 1, "checkInTime": "…"}]}
```

No patient id, no name, no core patient reference. That is enough to render a
position board and not enough to open a visit, which is what step 2 requires.

`POST /v1/external/scheduling/appointments/{externalId}/arrive` *does* return
`patientId` — but to whoever calls it, and in this flow that is check-in's own
UI, not us.

Either would work:

- **Patient identity on the queue read** — ideally `corePatientId` so it joins
  to the ac-core registry we both use, plus the `externalId` of the
  appointment. We would poll.
- **A push.** `POST /fhir/r4/Subscription` exists but carries no summary,
  request body or response schema, so we cannot tell whether it is usable. If
  FHIR Subscription is real, documenting it is enough. A plain signed webhook
  would also do — we already verify HMAC signatures on our own outbound
  deliveries and can mirror the scheme.

Push is preferable: polling a queue for arrivals adds latency to the one step
where a patient is standing at a desk waiting.

## 3. An external endpoint for room assignment

`POST /staff/patients/{id}/room` ("Assign a room to a patient") is behind
**staff JWT**, not the OAuth external surface. Step 3 produces a room decision
in scheduling that currently has nowhere federated to land.

An OAuth equivalent under `/v1/external/` with a `checkin:queue:write` scope —
or whatever fits your scope model — would close it.

## 4. A way to publish form requirements

The external forms surface reads the catalog
(`GET /v1/external/forms/definitions`) and accepts submissions. There is no way
to say **"this appointment requires these forms."**

What we want to publish is the **rule**, not a per-patient instruction:

> service code `svc_7a2f` requires forms `A`, `B`

Check-in applies it when it knows the appointment. That matters to us for a
specific reason — see "One constraint on our side" below.

Either shape works:

- A rules endpoint we push to: `service_code → [form definition ids]`.
- Or form requirements accepted on the appointment write, once (1) is done.

## 5. Minor spec defects

- `tokenUrl` is `http://ac-core/oauth/token` — plain HTTP and an internal
  hostname. Should be the reachable HTTPS issuer.
- 9 of the 10 `checkin:*` scopes used on endpoints are not declared in the
  `clientCredentials` flow's `scopes` map — only `checkin:queue:read` is.
  Generators read the declared list.

---

## One constraint on our side

Scheduling carries **PII but not health data** — clinical data lives in the
EMR. That is why ask 4 is for a *rule* endpoint rather than a per-patient one:
"patient Jane needs the stroke consent" is a clinical fact about a named
person, and this system will not hold or transmit it. "Service `svc_7a2f`
requires forms A and B" is a rule, and is fine.

For the same reason the service codes we send are **opaque** (`svc_7a2f`, not
`stroke-workup`). A descriptive code travelling next to a patient id is a
clinical label in all but name, and would land in request logs at both ends.

We would rather solve this at the interface than ask either team to be careful
in perpetuity. If the shape above is awkward for you, we are happy to work out
a different one that keeps the same property.

## What already works

Auth. `/v1/external/*` takes a client-credentials token issued and introspected
by ac-core, which is the same token source we already use for the core registry
(`Scheduling.Auth.ServiceToken`). We need the `checkin:*` scopes granted to our
service client and nothing else.

Also promising: `POST /v1/external/intake-refs` ("vendor intake reference,
pointer-only") is the same shape as the `compliance_ref` our queue entries
already carry. That may be where the two systems should meet on intake
pointers once the above is unblocked.
