# Booking

Scheduling owns booking: it publishes what is bookable, holds the
appointments, and hands the patient to check-in on arrival.

Until this, the app had **no time modelling at all** — no duration, no
timezone, no calendar. It was a live-queue router: a patient arrives, the
matcher finds a room with free concurrent capacity, they are served. Booking
sits beside that engine rather than replacing it.

## The shape

```
AVAILABILITY RULE          "Room 3, Mon–Fri 09:00–17:00, 20-minute slots"
        │  generated over a rolling horizon
        ▼
SLOT                       office_id, starts_at, ends_at, status
        │  one or more consecutive slots on the same office
        ▼
APPOINTMENT                patient, slots, required_capabilities, binding
        │  on arrival
        ▼
VISIT + QUEUE ENTRY        the existing lifecycle takes over
```

Slots always belong to an **office**, so capacity accounting is exact. What
varies is whether the appointment is *committed* to that office.

## Binding: committed vs provisional

The room is pinned exactly when there is **no routing decision to make**.

At booking, we compute the offices eligible for the service's capabilities
(`Scheduling.Matching.eligible_offices/3`, the same function the matcher uses):

| Eligible offices | Binding | On arrival |
|---|---|---|
| exactly 1 | `:committed` | straight to that room — nothing to decide |
| 2 or more | `:provisional` | the matcher picks, and may move the patient |
| 0 | booking refused | nobody can serve it |

This is **derived, not chosen**. An operator booking a scan into the only room
with a scanner gets a committed appointment without asking for one; booking a
routine consult into any of six rooms gets a provisional one. Neither has to
think about it.

Provisional bookings still hold a concrete slot — that is how capacity stays
exact — but the matcher is free to move them at arrival, releasing the slot.

### When a binding cannot be honoured

- **Provisional reroutes silently.** That is what provisional means; surfacing
  it would make the board noisy with routine events.
- **A committed appointment whose room can no longer serve it raises an alert**
  on the board, alongside the existing no-eligible-office alerts. Someone has
  to intervene before that patient arrives, and the board is where they will
  see it.

## What an appointment does *not* store

**The service code.** It is a transient input, expanded to the service's
default capabilities at booking and then discarded — exactly as
`Scheduling.Queue.create_entry/2` already treats it.

This is not fussiness. Scheduling holds a catalog mapping codes to
human-readable service names. If an appointment also held the code, this
database would contain patient → code → "Stroke Workup" — a named patient
linked to a clinical purpose, which is what `data-boundary.md` forbids and what
Phase 1 removed from queue entries. Storing only the resolved capabilities
means an appointment says *this person needs a CT scanner at 2pm*, never *why*.

Rescheduling moves the time and keeps the capabilities, so nothing needs the
code again.

## Duration

Slot length comes from the availability rule; **service length comes from the
catalog** (`diagnoses.duration_minutes`). An appointment consumes as many
consecutive slots on one office as its service requires:

    slots_needed = ceil(service_duration / rule_slot_minutes)

Booking therefore looks for a run of consecutive open slots, not a single one.
A 40-minute service on a 20-minute calendar takes two.

## Timezones

Availability rules are written in the office's local time — "Mon–Fri
09:00–17:00" means nine in the morning where the room is. Slots are stored in
UTC. Offices carry a `timezone`; ac-core locations already publish one, so a
synced office can inherit it (Phase 3d).

Without this, generation drifts an hour across a DST boundary and the calendar
quietly becomes wrong. It is not optional for anything real.

## Relationship to check-in

Check-in has a mirror of this model — `schedules`, `availability`, `slots`,
`appointments` under `/v1/external/scheduling/*` — and is the patient-facing
front door. Scheduling is the source of truth; check-in renders and takes
arrivals.

**Publishing is currently blocked.** Three of those endpoints are among the
eleven with no documented request body — see `checkin-integration-asks.md`.
The domain and our own API can be built now; the outbound adapter is a thin
layer to add once the schemas arrive.

The service code *is* sent to check-in at booking time as a pass-through — we
know it at that moment without storing it — so check-in can resolve which forms
the service requires.

## Open

- **Arrival signal.** Check-in registers the patient, but nothing tells us. The
  same blocking gap as the walk-in path.
- **Overbooking.** Not modelled. A slot holds one appointment; deliberate
  overbooking would need a per-rule allowance.
- **Provider-level booking.** ac-core has a provider directory. Today booking
  is against rooms and equipment, not people.
