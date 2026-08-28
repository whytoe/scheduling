# Design System — Scheduling UI

The calm-clinical look for the LiveView surfaces (board, queue, audit, CRUD,
system pages). It elevates the DaisyUI starter into a high-contrast clinical
system **without changing the state model, lifecycle, or audit schema**. Built
with HEEx + Tailwind 4 + DaisyUI 5 — no client framework.

## Where things live

| Concern | File |
|---|---|
| Theme, tokens, component CSS | `assets/css/app.css` |
| Reusable HEEx components | `lib/scheduling_web/components/core_components.ex` |
| App shell (navbar, theme toggle, flash) | `lib/scheduling_web/components/layouts.ex` |
| JS hooks (`ConfirmDialog`, `QueueList`) | `assets/js/app.js` |
| Timeline event presenter | `lib/scheduling_web/live/event_timeline.ex` |
| Fonts | linked in `lib/scheduling_web/components/layouts/root.html.heex` |

## Tokens

- **Fonts:** Public Sans (UI), IBM Plex Mono (codes/IDs/timestamps/rationale),
  set via Tailwind `@theme` `--font-sans` / `--font-mono`.
- **Color:** maps to DaisyUI `--color-*` slots (light default + dark). Indigo
  primary; info/success/warning/error carry the assigned/completed/attention/
  error roles.
- **State tokens (`--st-*`):** DaisyUI's four semantic slots can't express the
  full lifecycle, so the status system ships `--st-{waiting,assigned,active,
  success,attention,error,neutral,info}-{fg,bg,line}`, AA-verified on both
  themes. Light values live on `:root` (so "system" mode works); dark is
  overridden by `[data-theme=dark]` and by `prefers-color-scheme`.
- **Scales:** spacing `--s-1..--s-12` (4/8/12/16/24/32/48), type `--t-*`,
  radii `--radius-selector|field|box` (6/8/12px), elevation `--elev-*`, motion
  `--motion-arrival|state|ack`.
- **Elevation is earned:** flat by default; selection = ring + tint; pronounced
  shadow is reserved for the confirmation dialog.

## The component patterns

Built as HEEx function components; screens compose them.

1. **`status_badge`** — color + icon + text, always all three (color-blind safe).
2. **Patient card** (`.pcard`) — one structure, Board + Queue densities; priority
   is a numeric chip (`priority_tag`), not a hue; selection = ring + tint.
3. **`office_card`** — segmented load meter (used / incoming-hatched / free),
   turns red at 0 free.
4. **Audit row** (`.audit`) + **`timeline`** — expandable; mono timestamp,
   outcome badge, verbatim rationale, `actor` attribution pill.
5. **Inline edit form** (`.editform`) — "form above table", 3px indigo left edge,
   blank for new / pre-filled for edit.
6. **`empty_state`** — icon + reassuring "system is working" body.
7. **`callout`** — attention / error / info / neutral; optional dashed.
8. **`confirm_dialog`** — the only pronounced-elevation surface. Focus → Cancel,
   Tab trapped, Esc + backdrop cancel, focus returns (via `ConfirmDialog` hook).
   Body names the exact consequence.
9. **Skeletons** (`skel`, `skeleton_list`, `skeleton_table`) — reduced-motion-safe.

## Accessibility (WCAG 2.2 AA)

- Status is never color-alone — every badge/callout is color + icon + text.
- Visible `:focus-visible` rings (2px primary, 2px offset), never removed.
- `/queue` is fully arrow-key operable (`QueueList` hook: roving `tabindex`,
  `role=listbox`/`option`, ↑/↓ or j/k, Enter accepts; never auto-submits).
- Live regions announce board changes politely without stealing focus.
- Every animation has a `prefers-reduced-motion` fallback.
- Clinical accept/acknowledge targets are ≥ 56px (`btn-clinical`); copy is
  `gettext`-friendly (no concatenation, no idioms).

## Conventions

- Prefer the function components over ad-hoc markup; reach for the `--st-*`
  tokens (`var(--st-waiting-fg)` etc.) for lifecycle color, DaisyUI utilities
  for everything else.
- Custom component classes are declared unlayered in `app.css` so they take
  precedence over DaisyUI's same-named base classes.
- New audit/lifecycle surfaces should reuse the audit-row + `timeline` pattern
  (see `/visit_events` and `/visits`).

## Real-time board animations

- **Arrival** (`.is-arriving`): `BoardLive` tracks the ids present at the previous
  load; on a *live* update (not first paint) the newly-appearing ids get the
  one-shot `is-arriving` class, which plays the `arrive` keyframe. Each card
  carries a stable `id` (`w-/i-/a-<id>`) so morphdom matches by id — the class
  lands on the genuinely new card, not whatever shifted into its position. A
  `:clear_arrived` timer removes the highlight after the animation. Reduced
  motion is handled by the global `prefers-reduced-motion` rule (zeroes the
  duration), so cards appear instantly.
- **Acknowledge pulse** (`.is-acking`): the Acknowledge button chains
  `JS.add_class("is-acking", to: "#i-<id>")` before pushing the event, so the
  card pulses on click. Acknowledgement broadcasts over PubSub and removes the
  card near-instantly across every board (multi-client consistency), so the
  pulse is intentionally brief — the board never holds a stale card to finish an
  animation.
