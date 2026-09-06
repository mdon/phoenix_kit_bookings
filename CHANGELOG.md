# Changelog

All notable changes to **PhoenixKitBookings** are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/).

## 0.1.3 - 2026-09-06

The site's time frame stops being one number. Everything below follows from
that: a booking made in September for a November slot was stored an hour early,
and on a site using an IANA timezone id every slot was rendered and stored as
plain UTC.

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.14`** (was `~> 2.4`). Three things this
  module calls only exist, or only *work*, above that floor, and all three
  fail in the consumer's app rather than here — the workspace always resolves
  the newest core:

  - `Utils.Date.shift_to_offset/2` and `parse_datetime_local/2` resolve a
    zone per instant only from **2.14.1**, when core routed them through
    `Utils.TimeZone`. Below that they added `offset_to_seconds/1`, which was
    `Float.parse/1` and answered `0` for every IANA id — so the frame rewrite
    below would collapse to UTC and ship as a no-op. Unlike a missing
    function this raises nothing; it just stores the wrong instants.
  - `<.nav_tabs>`, used by the admin filter strips, reached its adoptable
    form in **2.13.5**.
  - `Utils.Slug.put_slug/3`, the existing **2.4.0** floor.

  Still two-segment, so every later 2.x satisfies it.
  `core_pin_conformance_test.exs` moved with it and now records all three
  reasons.

- **The site frame resolves the zone at the instant being converted.**
  `Engine.frame_to_utc/utc_to_frame` used to add `offset_to_seconds/1` of the
  `"time_zone"` setting — one scalar, applied to every date. Core's own
  docstring now calls that "a snapshot of the offset now" and points callers
  doing arithmetic across a daylight-saving boundary at `TimeZone.shift/2` and
  `from_wall/2`; both directions go through those now. New `to_frame/2` and
  `from_frame/2,3` take an explicit zone (an IANA id or a legacy fixed
  offset), and microseconds survive the round trip.

  A wall clock that never happens resolves to the instant the clocks jump to;
  one that happens twice resolves to the first occurrence — core's rules, not
  invented ones. Day/night services still touch no clock time at all.

- `Engine.bookings_to_events/3` and `blocking_events/2` take an optional zone,
  and `validate_request/5` resolves it once for the whole validation.
  `site_tz/0` is a settings query, and converting both ends of every active
  booking was making one per conversion — 43 queries to validate against 20
  active bookings, on every advisory check and again inside the locked create.

### Added

- **`bookings.time_zone`** (migration **V2**): the site's zone value at the
  moment a timed booking was made. A booking's instants are UTC and the wall
  clock the customer picked lived only in the site's zone at that moment — so
  when that setting moved to IANA ids and the frame turned out to have read it
  as one number, the existing rows could not be repaired: nothing recorded
  which zone each was made in. Nullable (day/night bookings carry no zone, and
  neither do rows written before V2).

  The chain now reports its applied version from a `bookings_schema:<N>`
  comment on the services table, the convention the CRM and projects chains
  use. A marker-less install whose tables exist reads as V1, and
  `down(version: 1)` drops only what V2 added.

- **`Engine.frame_span_intact?/5`** — true when the instants a frame-local
  span's wall clocks resolve to are as far apart as the clocks say. The slot
  grid marks a span that fails it `:unavailable`, and both public pickers
  refuse one outright.

### Fixed

- **A booking could be stored as a different length than the one picked.**
  Two Sundays a year a day is not 24 hours long, and the rules engine builds
  its grid from minutes without knowing that. On `Europe/Tallinn`, picking
  02:30–03:30 on a spring-forward Sunday asked for an hour, stored **thirty
  minutes** (03:00–03:59 never happens, so the end resolved to 04:00), and was
  then validated as a **ninety-minute** span — which a free-form service with
  a 30-minute minimum accepts. The 90-minute event then blocked other
  people's availability.

  Free-form services were fully exposed: they render no slot grid, so the
  grid's guard never saw the pick. `pick_slot` was exposed too — its start and
  end come from the client, so marking a button unavailable was a display
  fact, not a server-side one. Both pickers now check the span before building
  a range.

## 0.1.2 - 2026-08-14

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.4`.** `Service.changeset/2` now calls
  `PhoenixKit.Utils.Slug.put_slug/3`, which core did not ship until 2.4.0.
  The pin was raised from `~> 2.0` because that range admits cores where
  the function does not exist — and the failure would land in the
  **consumer's** app as an `UndefinedFunctionError` on every save touching
  `:name`, never in this repo's own run, since the workspace always
  resolves the newest core. Still two-segment, so every later 2.x
  satisfies it.

  `core_pin_conformance_test.exs` moved with it, and now guards both
  directions: too narrow (a three-segment pin collapsing to one minor)
  and too wide (a core lacking the function this module calls).

### Fixed

- **A Cyrillic or Greek service name could not be created.** The local
  slugifier was ASCII-only (`[^a-z0-9]` after downcase), so those names
  produced `""` and then failed this schema's own slug format
  validation. Core romanizes instead (#2).

- **Two services named alike hit a raw unique-constraint error.** Nothing
  probed `phoenix_kit_bookings_services_slug_index`. Slugs are now
  suffixed `-2`, `-3` … until free, and `max_length: 160` keeps the
  suffix inside the column — the old `String.slice(0, 160)` could
  overflow once a suffix was added (#2).

## 0.1.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.1.0 - 2026-08-11

First release. Requires `phoenix_kit ~> 2.0`.

### Added

- **The universal booking module** (#1) — one engine behind both shapes of
  booking: minute-unit services (appointments, classes, resources) and
  day/night services (stays), with `starts_at`/`ends_at` or
  `starts_on`/`ends_on` enforced exclusive by a database CHECK.

- **Services** with availability rules, per-service units, seats/capacity,
  buffers, min notice, max advance, min/max stay, check-in and check-out
  times, flexible durations, approval requirements and a
  `anyone` / `login_required` signup policy.

- **A locked create path.** `Engine.validate_request/5` is pure and advisory;
  `create_booking/4` re-runs it inside a transaction holding
  `SELECT … FOR UPDATE` on the service row — and, when a provider is attached,
  on all that provider's services in `uuid` order, so cross-service provider
  conflicts serialise without deadlocking. Expired holds are pruned inside the
  same transaction and the caller's own hold is excluded from the count.

- **Public booking surface** — a service listing, a booking flow, and a guest
  self-service page reached by a `Phoenix.Token`-signed manage link (90-day
  max age, no account needed) that cancels within the service's cancel window,
  re-checked server-side.

- **Holds, waitlist, pricing, ICS export**, an Oban reminder worker, activity
  logging, and admin pages for services, bookings and settings.

### Fixed before release

- **The migration could not run on a named-schema (`--prefix`) install.** All
  six `CREATE TABLE`s declared the primary key with a bare
  `uuid_generate_v7()`. Core installs that function into whichever schema it
  migrated into, so on a prefixed install `search_path` does not carry it and
  the statement fails outright. Every call is now schema-qualified, which costs
  nothing on a public install; guarded by a test that fails on a bare call.

- **The migration prefix was interpolated into DDL unvalidated.** It is now
  checked against an identifier pattern and raises otherwise, matching core and
  the other module-owned chains.
