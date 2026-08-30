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

## Availability rules

A rule is a recurring weekly statement: *"Room 3, Mondays, 09:00–17:00,
20-minute slots"*, bounded by `effective_from` / `effective_until`.

Three things about them are worth knowing before writing one.

**Times are the office's local wall time**, stored as `:time` with no offset.
"09:00" means nine in the morning where the room is, and it must keep meaning
that across a DST transition. Resolving to an instant happens at generation,
through the office's timezone. Storing an offset would freeze it at whatever it
was the day the rule was written.

**A rule is superseded, not edited.** Changing a room's hours means retiring
the old rule (`Scheduling.Booking.retire_availability_rule/2` sets
`effective_until` and deactivates it) and writing a new one. Editing in place
would silently rewrite what the calendar meant last month, and orphan the slots
already generated from it. `delete_availability_rule/1` exists for a rule
created in error, not for a schedule change.

Retiring clamps the date forward to the rule's own `effective_from`: a rule
scheduled to start next month cannot end today, and without clamping the write
failed validation silently. The rule is deactivated either way.

**A trailing part-slot is dropped, not rounded up.** A 09:00–17:00 window with
50-minute slots yields nine whole slots and a 30-minute remainder; the
remainder is discarded. A short slot is one an appointment cannot fit into, and
offering it would produce bookings that overrun the window.
`AvailabilityRule.slot_count/1` is the authority, and it floors.

A rule whose slot length exceeds its window is rejected at write time rather
than silently generating nothing — otherwise a room would simply never have
availability and nobody would know why.

`day_of_week` is 1–7 matching `Date.day_of_week/1`, so generation can compare
directly. A different convention here would shift every rule by a day.

## Slots

Rules expand into concrete slots across a rolling horizon
(`BOOKING_HORIZON_DAYS`, default 60). Slots carry a status — `:open`,
`:blocked` or `:booked`. Blocked and booked are distinct on purpose: a room
closed for cleaning and a room that is full are different facts, and
collapsing them would make one look like the other on a calendar.

A unique index on `(office_id, starts_at)` backs the whole thing: an office
cannot have two slots beginning at the same instant.

### A slot's start is a wall time; its length is not

This is the subtlety that makes DST handling correct, and it is easy to get
wrong in a way that looks fine for eleven months.

A rule says "09:00" in the office's local time, so the **start** resolves
through the timezone. The **end** is then simply start + `slot_minutes` as an
absolute duration — *not* a second wall-time conversion.

Resolving the end as a wall time discards real capacity. On spring-forward day
a 01:00–02:00 slot has an end ("02:00 local") that never happens, so the slot
gets thrown away — but it is a genuine attendable hour, 06:00Z to 07:00Z.
Treating length as absolute keeps it, and confines DST handling to one decision
instead of two.

### The two transitions

- **Spring forward** — the local start does not exist (`{:gap, _, _}`). Those
  slots are skipped: nobody can attend a time that never happens.
- **Fall back** — the local start happens twice (`{:ambiguous, first, second}`).
  We take the **first**. Generating both would double a room's capacity for an
  hour; this loses an hour of real capacity once a year per office, which is
  the better of the two errors but is not free.

### Generation is additive

Regeneration never destroys a `:booked` or `:blocked` slot — that is the
property that matters most, since silently dropping a booked slot would cancel
an appointment with nothing to show for it. Running it twice is a no-op.

**Nothing prunes.** Shortening a rule's window leaves its already-generated
slots in place, still open and bookable. Retiring the rule and writing a new
one is the supported path. A prune would have to be strictly `:open`-only —
a predicate slightly wrong there deletes booked slots — so it is deliberately
absent rather than half-done.

### Overlapping rules

Two rules for one office producing the same start instant is a data-entry
error, and it is detected before insertion rather than absorbed by the unique
index. Absorbing works, but hides the mistake behind behaviour that looks
correct. The lowest rule id wins, deterministically, so regeneration does not
reshuffle the calendar; the conflict is reported and logged.

### The horizon keeper

A periodic job tops the horizon up. It checks whether any availability rules
exist **once, at boot** — adding the very first rule to a running system will
not start it, so generate by hand or restart. The alternative was a timer that
exists only to discover it has nothing to do.

## The `/availability` screen

Admin-gated, alongside the other catalog screens. Lists rules per office with
their local window, slot length, effective range and the slots each yields;
creates and edits through the shared inline-form pattern; and retires through
the confirm dialog. Retired rules stay listed — a retired rule is the
explanation for slots that already exist.

Four things it cannot yet do, worth knowing before BK-8 proper:

- **It cannot say what a change costs.** The edit callout warns that existing
  slots are not revised, but not *which* ones. Saying "this leaves 47 open
  slots on Mondays after 15:00" needs a slot-counting context function that
  does not exist yet.
- **It cannot show whether a rule produced anything.** A new rule generates
  nothing until the next horizon run — and on a system with no rules at all,
  the keeper never starts. The flash says slots arrive "on the next horizon
  run", which is optimistic in exactly that case.
- **It will happily create an overlap.** Generation detects colliding start
  instants and resolves them lowest-rule-id-first, but nothing warns at write
  time.
- **Retirement is always "from today".** Scheduling one for a future date —
  "this room closes at the end of the month" — is the common real case and
  needs a date picker.

## Duration

Slot length comes from the availability rule; **service length comes from the
catalog** (`diagnoses.duration_minutes`). An appointment consumes as many
consecutive slots on one office as its service requires:

    slots_needed = ceil(service_duration / rule_slot_minutes)

Booking therefore looks for a run of consecutive open slots, not a single one.
A 40-minute service on a 20-minute calendar takes two.

## The booking engine

`Scheduling.Booking.book/1` runs five steps, each narrowing what the next has
to consider:

1. **Resolve the service** to its capabilities. The code is expanded and
   discarded.
2. **Find eligible offices** — those providing every required capability.
3. **Derive the binding** from how many there are.
4. **Find a contiguous run** of open slots long enough for the service.
5. **Reserve them** atomically.

### Eligibility is capability-only

`Matching.eligible_offices/3` is called with **no loads**. It filters on live
free capacity, which is right for the walk-in matcher and wrong here: for a
future appointment the capacity constraint is the slot, not today's queue.
Passing live loads would refuse to book tomorrow a room that happens to be busy
right now — there is a test for exactly that.

The default still excludes offices with `intake_capacity` 0, which is correct.

### Runs, not slot counts

`slot_minutes` varies per rule, so "how many slots" is not a division. The
engine walks actual slot boundaries until the run is long enough, and requires
`slot[i].ends_at == slot[i+1].starts_at` — a gap (a lunch break between two
rules) breaks the run rather than being booked through. The earliest qualifying
run across all eligible offices wins.

### Reservation is a compare-and-swap

The part that has to be right. Selecting candidate slots and then updating them
leaves a window where two callers both read `:open` and both write. Instead:

```sql
UPDATE slots SET status = 'booked', appointment_id = $1
 WHERE id = ANY($2) AND status = 'open'
```

…and **the affected row count must equal the number of slots intended**. Short
means someone took one in between; the transaction rolls back and the caller
gets `{:error, :slots_taken}`, which is the one error worth retrying.

`Engine.claim_slots/3` is public because it is the crux, and because it cannot
be reached through `book/1` in a test: `Ecto.Adapters.SQL.Sandbox` routes every
process through one connection, so nothing can take a slot in the window
between the search and the reservation. A "spawn N tasks" test would look
rigorous and prove nothing. The tests drive `claim_slots/3` directly instead —
same code path a genuine race takes — and separately assert that a rolled-back
transaction releases what it claimed, since the two halves of the guarantee
live in different places.

### Releasing is the inverse, and fails differently

`cancel/1` and `reschedule/2` hand slots back. That is **not** a
compare-and-swap: nobody contends for slots an appointment already owns, so
`WHERE appointment_id = $1` suffices, and matching zero rows is fine — it means
the release already happened, which makes cancelling idempotent.

The failure mode is the opposite of double-booking and quieter for it. A
release that does not happen **strands** capacity: slots stay `:booked` against
an appointment that no longer wants them, and the room silently offers less
than it has. Nobody gets an error; the calendar just shrinks. So release and
the status change are one transaction, and a failed reschedule rolls back to
the slots it had.

Rescheduling releases **before** it searches, which is what lets an appointment
move to a time overlapping its current one — its own slots are open again by
the time the search runs.

### A reschedule measures itself first

An appointment does not store the service code, so its length cannot be looked
up again. **The run it currently holds is the duration**, and it has to be
measured before the old slots are released — `Engine.booked_seconds/1`.

Getting this wrong is silent: a two-hour appointment rescheduled with a
zero-length requirement takes the first single slot it finds and quietly
becomes twenty minutes. There is a test that books six slots, moves the
appointment, and asserts it still holds six.

## Arrival

A booked patient turning up produces the same things a walk-in does — a `Visit`
and a `QueueEntry` — so the whole existing lifecycle (matching, handoffs,
completion, the board, the audit log) takes over unchanged. Booking decides
*when* and *what equipment*; the queue decides everything after the patient is
through the door.

`queue_entries.appointment_id` records which booking an entry came from, and is
nil for a walk-in.

**This is the only place the binding does anything.**

- **Committed** — one office could ever serve it, and it holds slots there.
  The entry is assigned directly and a handoff raised, exactly as
  `Queue.accept/2` would. Running the matcher would ask a question with one
  possible answer.
- **Provisional** — the entry is left `:waiting` and goes through
  `Queue.accept/2` like any other, so the matcher picks on **live capacity at
  the moment of arrival** rather than what was true at booking. It may well
  choose a different room from the one holding the slots; that is the point,
  and there is a test that fills the booked room and asserts the patient lands
  elsewhere.

Arriving twice returns the original visit and entry rather than opening a
second. Being checked in twice at a desk is a routine mistake, not something to
punish with a duplicate queue entry.

### Slots stay booked on arrival

A committed appointment's slots represent the room's time being spent, and the
patient is now spending it — releasing them would let a second patient be
booked into an occupied room.

Provisional slots stay booked too, **even when the matcher sends the patient
somewhere else**. Releasing them mid-session would hand back capacity the
original room had notionally set aside. Whether that should be reclaimed is a
scheduling-policy question, not something to decide implicitly — see Open below.

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
- **Rerouted provisional slots are not reclaimed.** When the matcher sends a
  provisional patient to a different room, the slots in the originally-booked
  room stay `:booked` for the rest of that window. Reclaiming them would return
  real capacity, but only if it is certain the patient will not come back to
  that room — a policy question worth deciding deliberately rather than by
  default.
