# Cross-resource reads: reporting endpoints vs GraphQL

**Status: decided — defer both. Add targeted reporting endpoints as concrete
needs surface; revisit GraphQL only when the trigger below fires.**

## The gap

There is no single call for a question that spans resources, e.g. *"every visit
in the last hour with its queue entries and their current status."* Today a
client stitches that together from several endpoints. That is fine at the
current integration count; this doc records the options and the line at which we
revisit, so the decision is deliberate rather than made in a hurry the first
time someone asks.

## What already covers most of it

- **`GET /api/board`** — a single-shot snapshot of the live board: waiting +
  active queue, per-office capacity, pending handoffs. This is the most common
  cross-resource read and it already exists.
- **`?since=<iso8601>`** on the event logs (`/api/v1/visit_events`,
  `/api/v1/routing_decisions`) — cheap incremental polling of the timeline.
- **List endpoints** — all now keyset-paginated (`?limit=&after=`), so bulk
  reads are bounded and stable.
- **Id filters** on `/api/v1/queue_entries` (`?intake_patient_id=` etc.) — the
  "does this patient already have an entry" question in one round-trip.

The gap is specifically *arbitrary* joins the above don't anticipate.

## Option 1 — targeted reporting endpoints

Add a purpose-built read endpoint each time a real need appears (e.g.
`GET /api/v1/reports/visits?since=…&include=queue_entries`).

- **For:** each is simple, cacheable, documented in the same OpenAPI spec, and
  authorised with the existing role/scope model. No new dependency or query
  language. Shapes stay predictable, which keeps generated clients simple.
- **Against:** the surface accumulates; two integrators wanting slightly
  different joins get two endpoints. Every new shape is a code change.

## Option 2 — a GraphQL endpoint (Absinthe)

Add `POST /api/v1/graphql` with [Absinthe], letting a client ask for exactly the
fields and nested resources it wants in one query.

- **For:** one endpoint serves arbitrary read shapes; integrators stop waiting
  on us for each new join; over-/under-fetching goes away.
- **Against:** a real new dependency and a second API paradigm to secure and
  operate. Field-level authorisation must be re-expressed in the resolver layer
  (our per-office scoping and role checks live in the REST pipelines today), and
  getting that wrong is a data-exposure bug. Query-cost / depth limiting becomes
  our problem (a naive nested query is a DoS). It does not fit the OpenAPI spec
  the SDK story (`docs/generated-clients.md`) is built around, so integrators
  get two toolchains. This is the same "one powerful surface, but you own its
  safety" trade the GraphQL hunting notes flag.

## Decision

**Defer both, prefer Option 1 when a need is concrete.** Rationale:

- The board snapshot + `?since=` polling + paginated lists cover every read
  pattern an integrator has actually asked for so far.
- A targeted endpoint reuses the authorisation, pagination, and OpenAPI
  machinery already in place; GraphQL would require re-implementing
  authorisation and adding cost-limiting before it could be exposed safely.
- Adding endpoints is reversible and incremental; adopting GraphQL is a
  standing commitment.

### The line to revisit GraphQL

Flip to Option 2 when **both** hold:

1. **Two or more** integrators need **arbitrary, differing** cross-resource read
   shapes — not one more fixed report, which Option 1 handles.
2. The added endpoints are churning enough that maintaining them costs more than
   standing up and securing Absinthe would.

When that happens, the non-negotiable prerequisites before exposing it:
field-level authorisation mirroring the REST scoping (per-office + role), a
query depth/complexity limit, and a decision on whether it complements or
replaces the REST read surface (it should complement — writes stay REST).

Until then, this bead stays open as the recorded decision, not as pending work.

[Absinthe]: https://hexdocs.pm/absinthe
