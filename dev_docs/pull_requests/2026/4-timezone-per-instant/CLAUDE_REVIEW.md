# PR #4 — Resolve the site frame per instant; V2 keeps the zone a booking was made in

**Author:** mdon · **Branch:** `pr/timezone-per-instant` · **Merged:** `a30e96a` ·
**Reviewed:** 2026-09-06

Four commits: the frame conversions stop collapsing the `"time_zone"` setting
into one number, the slot grid learns that two Sundays a year are not 24 hours
long, and a V2 migration records on every timed booking which zone it was made
in. Reviewed against core 2.15.1 (`Utils.Date` → `Utils.TimeZone`) and
`phoenix_live_calendar`'s `Constraints`.

## What holds up

**The diagnosis and the fix.** `utc_to_frame`/`frame_to_utc` used to add
`offset_to_seconds/1` of the setting — one scalar. Core's own docstring on that
function now says so in as many words: it is "a snapshot of the offset now", and
callers doing arithmetic across a daylight-saving boundary want `shift/2` or
`from_wall/2`. The PR routes both directions through exactly those
(`shift_to_offset/2` and `parse_datetime_local/2`), which resolve
`DateTime.shift_zone/3` and `DateTime.from_naive/3` at the instant being
converted. The two documented failure modes were real: plain UTC on an IANA site
before core 2.14.1 (`Float.parse("Europe/Tallinn")` → 0), and today's offset
applied to every date after it.

**The ambiguity rules are the ones core states, not invented ones.**
`TimeZone.from_wall/2` resolves a gap clock to the instant the clocks jump to and
an ambiguous one to the first occurrence; `from_frame/3`'s docstring says the
same, and the tests pin both against Tallinn's 2026 transitions.

**Microseconds round-trip.** `parse_datetime_local/2` takes a whole-second
string, so `from_frame/3` re-adds them and restores the original precision tuple.
Worth the four lines: `Booking.put_range/2` truncates to seconds, but
`Hold`/comparison paths do not.

**Dropping the `rescue`/`catch :exit` around the settings read is correct, not a
regression.** Core's `get_setting/1` rescues *and* catches exits and answers
`nil`, so `get_setting("time_zone", "0")` still yields `"0"` on an unreachable
database — the guard really was redundant.

**The V2 marker protocol matches core's coordinator.** A missing table returns
zero rows from the `pg_description` join and falls to `_ -> 0`; a marker-less
table reads `1`; the marker is stamped last, after the statements it certifies.
`down(version: 1)` going back to V1 without dropping the tables is exactly the
shape `mix phoenix_kit.update` generates (`update.ex:1184-1188`: `up(version:
<target>)` / `down(version: <installed-at-generation>)`).

**`slot_intact?` is not a heuristic.** It compares the nominal wall-clock span
against the span of the instants those clocks resolve to. That is the right
invariant, and it is why 02:30–03:00 stays available on the spring-forward day
(its end *is* the jump) while 02:30–03:30 does not.

---

## BUG - HIGH — the daylight-saving guard never runs for free-form services

`slot_intact?` is applied in `Engine.bookable_slots/5` only — the fixed-slot
grid. Two paths reach `frame_to_utc/2` without ever passing through it:

- **Free-form services have no grid at all.** `BookingFlow.refresh_pick/1` is
  explicit: `if service.flexible_duration, do: [], else: Engine.bookable_slots(...)`.
  A flexible service renders a start/end input pair (`picker/1`, the
  `flexible_duration: true` clause) handled by `pick_free`, which built a range
  from whatever wall clocks arrived.
- **`pick_slot` trusts its payload.** `%{"start" => ..., "end" => ...}` comes from
  the client and was never checked against the rendered grid, so marking a button
  `:unavailable` is a display fact, not a server-side one.

The failure is worse than a rejected booking, because three different durations
result from one pick. Gym service on `Europe/Tallinn`, free-form, min 30 minutes,
customer picks 02:30 → 03:30 on 2027-03-28 (clocks go 03:00 → 04:00):

| | |
|---|---|
| asked for | 60 minutes |
| `frame_to_utc` stores | `00:30Z` → `01:00Z` — **30 real minutes** |
| `validate_request` sees | `utc_to_frame` gives 02:30 → 04:00 — **a 90-minute frame span**, which passes a min-30/no-max config |
| the calendar then blocks | 90 minutes of other people's availability |

Reproduced before fixing: the flow accepted the pick and rendered the confirmation
panel reading `28 Mar 2027 02:30 – 04:00`.

**Fixed.** The predicate is now public — `Engine.frame_span_intact?/5`, with
`slot_intact?/4` reduced to deriving the end date and delegating — and both
public pickers put it in their `with` chain, so a broken span is refused with
`Errors.message(:invalid_range)` instead of becoming a range. The fixed-slot grid
keeps marking such slots `:unavailable`; the predicate is now the thing that
actually decides. Locked in by a `frame_span_intact?/5` unit test (gap, overlap,
ends-at-the-jump, ordinary day, fixed offset, midnight-crossing) and a LiveView
test that submits the gap span to a free-form service, asserts the flow stays on
the picker with nothing written, and then books an ordinary span on the same day.

## BUG - HIGH — the core pin admits cores where the whole fix is a no-op

`mix.exs` pinned `{:phoenix_kit, "~> 2.4"}`. The rewritten frame calls
`Utils.Date.shift_to_offset/2` and `parse_datetime_local/2`, and the PR's own
comment is right that both are "older than the 2.0 pin" — but their *per-instant*
behavior is not. Core routed them through `Utils.TimeZone` (`shift/2` /
`from_wall/2`) in **2.14.1**, released the day before this PR merged. Core's own
2.14.1 entry names this module as one of the three downstream consumers it was
fixing, by function:

> ⚠️ **This one reaches outside core.** Three call sites in module packages take
> that number as gospel … `phoenix_kit_bookings`' `site_offset_seconds/0`

Below that, `shift_to_offset/2` was `DateTime.add(dt, offset_to_seconds(tz))` and
`offset_to_seconds/1` was `Float.parse/1` — `0` for every IANA id. So on any core
in 2.4–2.14.0 the new `to_frame/2` returns the instant unchanged and `from_frame/3`
reads every wall clock as UTC: the site frame collapses to UTC, `frame_span_intact?/5`
is always true, and the release ships the *exact bug it claims to fix*, silently.
No exception is raised anywhere, and it cannot show up in this repo's run — the
workspace always resolves the newest core (2.15.1 here).

This is the failure mode `core_pin_conformance_test.exs` was written for, in the
direction its own moduledoc calls "too wide rather than too narrow" — and the
0.1.2 release set the precedent by moving the floor from `~> 2.0` to `~> 2.4` for
`put_slug/3`. PR #3, also unreleased, pushes the same floor independently: the
admin filter strips render core's `<.nav_tabs>`, which reached its adoptable form
in 2.13.5.

**Fixed.** The pin is now `~> 2.14` — two-segment, so every later 2.x still
satisfies it, which is the shape all 32 modules use and the one
`phoenix_kit_publishing` (the other timezone consumer core named) already sits
at. `@must_admit`/`@must_reject` and the moduledoc moved with it, listing all
three reasons the floor is where it is.

One honest gap on record: `~> 2.14` admits **2.14.0**, which has the
`<.nav_tabs>` and `put_slug/3` but not the per-instant delegation. Excluding it
needs a compound `>= 2.14.1 and < 3.0.0`, which no module in the ecosystem uses;
2.14.0 was superseded within a day and Hex resolves the newest satisfying
release, so the exposure is a host with a lockfile pinned to that one version.
The conformance test's entries are written to assert the requirement (2.13.x and
older out, every later minor in) rather than one string's shape, so tightening to
the compound form later needs no test change.

## IMPROVEMENT - MEDIUM — one settings query per conversion, on the hottest path

`site_tz/0` is a `Settings.get_setting/2` call, i.e. a database round-trip, and
`utc_to_frame/1` calls it per conversion. `bookings_to_events/2` converts **both
ends of every active booking**, so a `validate_request/5` against 20 active
bookings was 43 settings queries — on every keystroke-driven advisory check and
again inside the locked create.

The PR already solved this correctly for the slot grid: `bookable_slots/5`
resolves the zone once and hands it to `slot_intact?/4`, which is why a 48-slot
grid costs one read. The same treatment now covers the rest —
`validate_request/5` resolves `tz` once and passes it to `to_frame/2` and
`bookings_to_events/3`; `bookings_to_events/3` and `blocking_events/2` gained an
optional trailing zone argument defaulting to `site_tz()`, so every existing
call site keeps working and the ones that already know the zone stop re-reading
it. `bookable_slots/5` now threads its zone into its event mapping too, which it
was not doing.

## IMPROVEMENT - MEDIUM — `bookings.time_zone` is written and never read

`Booking.put_range/2` stamps the column on every timed booking, and nothing reads
it: `Web.Format.range/1` and `BookingFlow`'s summary still display through
`Engine.utc_to_frame/1`, i.e. the site's *current* zone. So if the setting ever
changes, every existing booking displays in the new zone while the row records
the old one.

**Deliberately not fixed.** The column's stated purpose is repairability — the
V2 docstring is explicit that the previous breakage was unfixable because
"nothing said which zone each was made in" — and that purpose is served by
writing it. Making display per-row is a product decision, not a bug fix: for a
physical venue that genuinely relocates, the *current* zone is arguably the right
answer for future bookings, and switching the display would silently rewrite what
staff see for every historical row. Recording it now is what keeps that decision
open. Left on record here rather than half-implemented.

## NITPICK — `down(version: N)` for N ≥ current still rolls back

`down/1` branches on `target >= 1`, so `down(prefix: ..., version: 2)` on a V2
install drops the `time_zone` column and restamps the marker to `1` — a rollback
to the version you are already on. Unreachable through core, which only ever
generates `down(version: <the version installed when the wrapper was written>)`,
so it is left alone rather than adding a guard to a path nothing calls.

---

## Validation

`mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
`hex.audit`, `format --check-formatted`, `credo --strict`, `dialyzer`) clean.
`mix test`: 118 tests, 0 failures, integration tests included (the test database
was reachable).
