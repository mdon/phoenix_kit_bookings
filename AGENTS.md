# phoenix_kit_bookings — agent notes

Universal booking module for PhoenixKit. Read the workspace `../AGENTS.md`
first for ecosystem-wide conventions; this file covers only what is
specific to this module.

## Architecture

```
Schemas.Service            one bookable offer; the WHOLE booking shape is per-service
Schemas.AvailabilityRule   weekly rule | date override | block-out (maps 1:1 to lib Availability)
Schemas.Booking            timed pair OR date pair (DB CHECK bookings_time_shape), exclusive ends
Engine                     adapter onto phoenix_live_calendar's booking layer (minute units)
Engine.DayEngine           the date-granular path the lib doesn't cover (day/night services)
Services / Bookings        contexts; Bookings.create_booking is the race-proof choke point
Policy                     ALL admin authorization + self-service rules (LVs never call
                           Services/Bookings mutations directly for admin actions)
Web.Admin.*                ServicesLive, ServiceFormLive, BookingsLive, SettingsLive (tabs-driven routes)
Web.Public.*               BookingFlow (shared logic+markup) + BookLive (routed) +
                           BookingWidgetLive (live_render embeddable) + ServicesLive + ManageLive
Migrations.Schema          module-owned versioned migration (stats/legal protocol)
```

## Load-bearing decisions

- **One booking model, three shapes.** Universal products (Checkfront /
  Planyo / Mews — see `dev_docs/research/`) store one record type and
  drive behavior from per-resource config. A booking row is EITHER
  `starts_at/ends_at` (UTC, minute services) OR `starts_on/ends_on`
  (DATE, day/night services) under a CHECK — the `phoenix_kit_calendar`
  V141 convention. Check-in/out clock times are service ATTRIBUTES and
  never enter availability math.
- **The rules engine is `phoenix_live_calendar`'s** (`BookingConfig`,
  `Availability`, `Constraints.validate_booking`, `TimeSlots.bookable_slots`)
  — do not rebuild it. `Engine` maps rows onto lib structs. Two adapter
  subtleties:
  - `overlap: seats > 1` on mapped events — with one seat the event must
    BLOCK (`validate_no_overlap` rejects only `overlap: false`); with
    pooled seats events must pass overlap and be COUNTED by capacity.
  - Events are pre-expanded by the service buffers because the lib
    buffers only the REQUEST; expanded-vs-expanded means consecutive
    bookings need `buffer_after + buffer_before` of gap. The conflict
    query window (`Bookings.conflict_window/2`) pads each side by BOTH
    buffers for the same reason — shrinking it reintroduces a real bug
    (a booking just outside the raw range escaped the reload).
- **Unbounded duration** (`max_duration: nil` + `flexible_duration`) maps
  to a large sentinel (`@unbounded_minutes`) because the lib treats nil
  as "same as duration". Candidate upstream tweak in the lib.
- **Race-proofing**: `create_booking` re-validates inside a transaction
  holding `FOR UPDATE` on the service row. The pure `Engine.validate_request`
  call in the public flow is advisory UX only.
- **Time frame**: minute-unit math runs in the SITE frame — the wall clock
  of core's `"time_zone"` setting, an IANA id or a legacy fixed offset (v1
  services are physical venues — the Cal.com `lockTimeZoneToggleOnBookingPage`
  behavior). Storage is true UTC via `Engine.frame_to_utc/utc_to_frame`,
  which resolve the zone AT THE INSTANT CONVERTED through core's per-instant
  helpers; never turn the setting into one number and add it — that was an
  hour off across every daylight-saving switch (and plain UTC on IANA sites
  before core 2.14.1). **That is why the core pin is `~> 2.14`** — those
  helpers only became per-instant in 2.14.1, and below it the frame collapses
  to UTC without raising anything. Day/night uses bare dates, no tz math ever.
- **Two Sundays a year a day is not 24 hours long**, and the lib's grid is
  built from minutes. `Engine.frame_span_intact?/5` is the guard: a span whose
  wall clocks resolve to instants a different distance apart is refused.
  Every path that turns a wall clock into a range must call it — the slot grid
  marks such slots `:unavailable`, and BOTH public pickers check it before
  building a range, because a free-form service renders no grid and
  `pick_slot`'s params come from the client. Without it a 02:30–03:30 pick was
  asked as 60 minutes, stored as 30 and validated as 90.
- **Permission orientation** (core's sub-implies-base forces it): base
  `bookings` = admin area scoped to OWNED services (`owner_uuid`;
  nil = site service); sub `bookings.manage_all` = everything + settings.
  Self-service settings: `bookings_user_services_enabled` (default OFF)
  and `bookings_max_services_per_user` (`0` = unlimited).
- **Embeddable LVs must not export `handle_params/3`** (the
  `phoenix_kit_projects` lesson) — hence the BookLive/BookingWidgetLive
  split with all logic in `BookingFlow`.
- **Manage tokens**: `Phoenix.Token` signed against the HOST endpoint —
  resolution order in `Bookings.token_endpoint/0` is explicit
  `config :phoenix_kit, endpoint:` (tests) → core's
  `Config.get_parent_endpoint/0` (host apps) → `PhoenixKitWeb.Endpoint`.
  Core's own endpoint is compiled but not running in a host; signing
  against it crashes on the ETS lookup (found in browser verification).

## Migrations

Module-owned (`migration_module/0` protocol, like `phoenix_kit_stats` /
`phoenix_kit_legal`): `Migrations.Schema` with `current_version/0`,
`migrated_version_runtime/1`, idempotent `up/1`/`down/1` with `:prefix`
support. `mix phoenix_kit.update` applies it in host apps; tests run it via
`Test.SchemaMigration` + `Ecto.Migrator` (see `test_helper.exs`). While
v0.1.0 is unreleased, edit V1 in place (workspace convention).

## Testing

- `mix test.setup && mix test` — 118 tests. Engine/DayEngine tests are pure
  (no DB); contexts + LVs are `:integration` (auto-excluded without DB).
- `test_helper.exs` enables the module setting BEFORE sandbox mode —
  `Scope.can?/2` gates on module enablement, so Policy checks would
  otherwise fail closed suite-wide.
- `LiveCase.fake_scope/1` defaults to a site-wide admin
  (`["bookings", "bookings.manage_all"]`); pass `permissions: ["bookings"]`
  for an own-services-only user.
- Public LVs render through `LayoutWrapper.app_layout`; tests point
  `config :phoenix_kit, layout:` at `Test.Layouts.public` because the
  fallback (core's root layout) needs core's endpoint started.

## v1.5 additions (2026-07-25, "do everything" pass)

- **Named units** (`Schemas.Unit`): capacity = active-unit count when any
  exist; `pick_unit` auto-assigns first-free-by-name inside the locked
  create. Legacy nil-unit bookings consume capacity without a unit — safe.
- **Holds** (`Schemas.Hold`): separate table, same either/or time CHECK;
  mapped to pseudo-bookings by `Bookings.list_occupancy/3` so EVERY
  capacity read (picker, advisory, locked create) sees them; expired rows
  are ignored + lazily pruned; the flow's own hold is excluded via
  `exclude_hold` and consumed at create. Public LVs release on
  `terminate/2` / Back.
- **Providers**: `service.provider_uuid` (loose staff ref). Cross-service
  conflicts via `provider_blocking_events` (absolute blocks, no buffer
  expansion) + `lock_service_tree` (locks ALL the provider's services in
  uuid order — deadlock-safe). Admin select reads
  `phoenix_kit_staff_people` SCHEMALESSLY (to_regclass guard) — never a
  compile-time staff reference.
- **Pricing** (`Pricing`): totals stamped on bookings inside the create;
  `price_per` shape mismatches degrade to flat price. NO payment
  collection — billing checkout is a decision for Max (pay-at-booking vs
  deposit vs invoice), not a default.
- **Emails** (`Notifier` + `ICS` + `Workers.ReminderWorker`): all sends
  best-effort (rescue+log — mail failure never fails the operation);
  reminder jobs re-check state at fire time so cancellations need no job
  bookkeeping; tests assert via Swoosh.Adapters.Test (config/test.exs) —
  note assert_email_sent pops IN ORDER, consume the confirmation first.
- **Waitlist** (`Schemas.WaitlistEntry`): notify-all-first-to-book on the
  freed dates of a cancellation; join idempotent per email+date.
- **Cancellation windows**: `cancel_notice` minutes;
  `Bookings.cancellable_by_customer?/2` gates ManageLive (re-checked
  server-side on the event, not just button-hiding).

## Known gaps / next decisions (deliberately NOT built)

- **Payment collection** — needs Max's UX call (pay-at-booking vs deposit
  vs invoice-later); prices/totals are already recorded so billing can
  plug into `create_booking`'s success path.
- **External calendar sync** (Google/Outlook OAuth) — needs provider
  credentials; the `.ics` attachment covers the import case.
- **Recurring bookings** — data-model choice (series table vs rrule)
  worth boss review first.
- Viewer-timezone slot display for virtual services; per-date (seasonal)
  pricing rules; named-unit selection BY the customer (auto-assign only).
