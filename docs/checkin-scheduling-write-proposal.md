# Proposed request-body schemas — check-in scheduling write endpoints

A concrete answer to **ask #1** in `checkin-integration-asks.md` (the blocking
one). That ask says the `/v1/external/scheduling/*` write endpoints document a
response but no request body, and that because we generate our client from the
spec we cannot build against them until the request schemas exist.

Rather than leave it as an open request, this proposes the schemas — derived
from **check-in's own GET response vocabulary** (`ac-checkin.json`), the write
endpoints' own summaries, and the data we hold on the scheduling side. **These
are a starting point for check-in to confirm or amend**, not a demand: the
field names and shapes below deliberately mirror what check-in already returns
from `GET /v1/external/scheduling/appointments` and `.../slots`, so adopting
them should be close to free.

If any shape is awkward on check-in's side, we would rather work out a
different one than have either team build against a guess.

---

## Conventions (from check-in's existing responses)

These hold across every endpoint below and are taken from the API as it already
stands, not invented here:

- **`externalId` is our id, and the idempotency key.** Every write is an
  upsert keyed on it — which matches the "idempotent" note in the appointments
  and schedules summaries. It is the caller's (scheduling's) stable id for the
  record; check-in's own `id` is returned in the response.
- **Ids are in the ac-core space.** `corePatientId` and `locationId` name rows
  in the ac-core registry both systems already share, so they join without a
  translation table. This is the same id space `GET .../appointments` returns.
- **Timestamps are ISO-8601 UTC** (`start`, `end`) — as in the GET responses.
  The one exception is availability, whose times are **office-local wall
  clock** plus an explicit `timezone` (see that section).
- **camelCase**, matching the rest of the external surface.

## One modelling gap to settle first: provider vs room

Check-in's appointment and slot reads carry `coreProviderId`. **Scheduling does
not book against providers.** It books against **rooms and equipment** —
capabilities like "CT scanner" — and derives the room from them; provider-level
booking is explicitly not modelled yet (`docs/booking.md`, "Open"). So we have
no `coreProviderId` to send.

Two ways forward, check-in's call:

1. Make `coreProviderId` **optional** on these writes, and let `locationId` +
   our opaque `serviceCode` carry the routing. This is what the schemas below
   assume.
2. If a provider is genuinely required on check-in's side, tell us — it changes
   what scheduling has to model, and is worth knowing before either team builds.

## What scheduling will never send, and why

Per `docs/data-boundary.md`: **scheduling carries PII but not health data.** Two
fields on check-in's appointment read are therefore ones we will not populate:

- **`reason`** — a clinical reason is PHI. Omitted.
- **`visitType`** — names a clinical purpose. Omitted.

In their place we send **`serviceCode`**: an **opaque** identifier (`svc_7a2f`,
never `stroke-workup`). Check-in uses it to resolve which forms a service
requires (this is also the hook for ask #4). A descriptive code travelling next
to a patient id would be a clinical label in all but name and would land in
request logs at both ends, so the code is deliberately meaningless outside the
two systems' shared table.

---

## Who calls what

Of the six write endpoints, **scheduling calls five** — it is the source of
truth that publishes bookings into check-in:

- `POST  /v1/external/scheduling/appointments`
- `PATCH /v1/external/scheduling/appointments/{externalId}`
- `POST  /v1/external/scheduling/schedules`
- `POST  /v1/external/scheduling/availability`
- `PATCH /v1/external/scheduling/slots/{externalId}`

The sixth, `POST .../appointments/{externalId}/arrive`, is **check-in-initiated**
— check-in's own desk marks the patient arrived. Its request body is check-in's
to define; it is included at the end only for completeness and because it is
bound up with **ask #2** (an arrival signal that reaches scheduling).

---

## 1. `POST /v1/external/scheduling/appointments`

> *Book an appointment (OAuth, tenant-scoped, idempotent)*

| Field | Type | Req | Source on our side | Notes |
|---|---|:--:|---|---|
| `externalId` | string | ✅ | our appointment id | upsert key |
| `corePatientId` | string (uuid) | ✅ | `patients.core_patient_id` | ac-core registry id |
| `locationId` | string | ✅ | office → `locations.core_location_id` | the room's ac-core location |
| `start` | string (ISO-8601) | ✅ | appointment's earliest slot start | UTC |
| `end` | string (ISO-8601) | ✅ | appointment's latest slot end | UTC |
| `status` | string | ✅ | `booked` \| `arrived` \| `completed` \| `cancelled` | our appointment status |
| `serviceCode` | string | ✅ | opaque service code (pass-through) | resolves required forms; never a clinical label |
| `binding` | string |  | `committed` \| `provisional` | whether the room is pinned; optional — omit if check-in does not use it |
| `coreProviderId` | string |  | — | we do not book against providers; see gap above |

```json
{
  "externalId": "sched-appt-4821",
  "corePatientId": "3f8c2a10-7b4e-4c1d-9a5e-2b6f0d1e4c77",
  "locationId": "loc_9c31",
  "start": "2026-09-28T14:00:00Z",
  "end": "2026-09-28T14:20:00Z",
  "status": "booked",
  "serviceCode": "svc_7a2f",
  "binding": "committed"
}
```

## 2. `PATCH /v1/external/scheduling/appointments/{externalId}`

> *Reschedule / cancel / update an appointment (OAuth, tenant-scoped)*

A partial update keyed on the path `externalId`; every body field is optional
and only the ones present change. Covers the three named operations:

- **Cancel** → `{"status": "cancelled"}`
- **Reschedule** → new `start` / `end` (and `locationId` if the room changed —
  a provisional appointment's binding is re-derived on reschedule)
- **Update** → any subset

| Field | Type | Req | Source | Notes |
|---|---|:--:|---|---|
| `status` | string |  | our appointment status | e.g. `cancelled` |
| `start` | string (ISO-8601) |  | new earliest slot start | reschedule |
| `end` | string (ISO-8601) |  | new latest slot end | reschedule |
| `locationId` | string |  | office → `core_location_id` | if the room changed |
| `serviceCode` | string |  | opaque | only if it changed |

```json
{ "status": "cancelled" }
```

## 3. `POST /v1/external/scheduling/schedules`

> *Create/update a bookable schedule (OAuth, tenant-scoped, idempotent)*

A "schedule" is the bookable resource that slots hang off (check-in's slots
carry `scheduleExternalId`). On the scheduling side that resource is a **room /
office**, not a provider.

| Field | Type | Req | Source | Notes |
|---|---|:--:|---|---|
| `externalId` | string | ✅ | our office id | upsert key; slots reference it as `scheduleExternalId` |
| `locationId` | string | ✅ | `locations.core_location_id` | the office's ac-core location |
| `name` | string |  | `offices.name` | a room label ("Imaging Suite") — not clinical |
| `timezone` | string |  | `offices.timezone` (IANA) | availability times are interpreted in it |
| `active` | boolean |  | derived | false when the room is retired |
| `coreProviderId` | string |  | — | not applicable; see gap above |

```json
{
  "externalId": "sched-office-12",
  "locationId": "loc_9c31",
  "name": "Imaging Suite",
  "timezone": "America/New_York",
  "active": true
}
```

## 4. `POST /v1/external/scheduling/availability`

> *Publish a recurring availability rule + generate slots (OAuth, tenant-scoped)*

Maps one-to-one to our `availability_rules`. Times are the office's **local wall
clock** ("Mon–Fri 09:00–17:00 means nine in the morning where the room is") plus
an explicit IANA `timezone` — not UTC — so a rule survives DST without drifting.

| Field | Type | Req | Source | Notes |
|---|---|:--:|---|---|
| `externalId` | string | ✅ | our availability-rule id | upsert key |
| `scheduleExternalId` | string | ✅ | the office/schedule id (§3) | which resource this rule fills |
| `dayOfWeek` | integer (0–6) | ✅ | `day_of_week` | 0 = Sunday |
| `start` | string (`HH:MM`) | ✅ | `starts_at` | office-local wall time |
| `end` | string (`HH:MM`) | ✅ | `ends_at` | office-local wall time |
| `slotMinutes` | integer | ✅ | `slot_minutes` | length of each generated slot |
| `timezone` | string | ✅ | `offices.timezone` (IANA) | the zone `start`/`end` are read in |
| `effectiveFrom` | string (date) |  | `effective_from` | when the rule starts applying |
| `effectiveUntil` | string (date) |  | `effective_until` | nullable — open-ended when absent |
| `active` | boolean |  | `active` | |

```json
{
  "externalId": "sched-rule-77",
  "scheduleExternalId": "sched-office-12",
  "dayOfWeek": 1,
  "start": "09:00",
  "end": "17:00",
  "slotMinutes": 20,
  "timezone": "America/New_York",
  "effectiveFrom": "2026-10-01",
  "effectiveUntil": null,
  "active": true
}
```

## 5. `PATCH /v1/external/scheduling/slots/{externalId}`

> *Block/unblock a slot (OAuth, tenant-scoped)*

Keyed on the path `externalId` (our slot id). The one meaningful change is the
status.

| Field | Type | Req | Source | Notes |
|---|---|:--:|---|---|
| `status` | string | ✅ | `open` \| `blocked` | `booked` is reached by booking an appointment, not by this endpoint |

```json
{ "status": "blocked" }
```

---

## 6. `POST /v1/external/scheduling/appointments/{externalId}/arrive` — check-in-initiated

> *Mark an appointment arrived and land the patient into the check-in queue*

**Scheduling does not call this** — check-in's desk does, when the patient
arrives there. It is listed only for completeness and because it is the natural
home for **ask #2**: today its `200` returns `patientId`/`queuePosition`/`status`
to *its* caller (check-in's UI), which is not scheduling, so the arrival never
reaches us. A minimal request body is all it needs:

| Field | Type | Req | Notes |
|---|---|:--:|---|
| `arrivedAt` | string (ISO-8601) |  | defaults to now if omitted |

The unblock scheduling actually needs here is not the request body but a way for
the arrival to reach us — patient identity on `GET /v1/external/queue`
(ideally `corePatientId`), or a push. See ask #2.

---

## Summary of the asks this settles

- **Ask #1 (blocking):** the five schemas scheduling needs to publish are above,
  in check-in's own vocabulary. Confirm or amend and we can generate the client.
- **The provider/room gap:** please confirm `coreProviderId` can be optional on
  these writes (or tell us it is required, which changes our model).
- **Ask #4 (forms):** the `serviceCode` on the appointment write is the hook —
  once check-in resolves forms from it, "this appointment requires these forms"
  needs no per-patient, clinical instruction to cross the boundary.
