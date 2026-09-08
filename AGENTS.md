# AGENTS.md

Guidance for AI agents working on `phoenix_kit_bookings`.

## Overview

Universal booking module for PhoenixKit. One install mixes bookable services
of entirely different shapes because the shape is per-service configuration,
never a module setting: day/night stays (`time_unit: "day" | "night"`, pooled
`seats`, min/max stay, check-in/out display times), fixed slots
(`time_unit: "minutes"`, `duration` + `slot_interval`) and free-form ranges
(`flexible_duration: true`, `min_duration`/`max_duration`, nil = unbounded).
Public pages let guests or logged-in users pick a slot, hold it while they fill
in details, manage the booking through a signed token and join a waitlist;
the admin manages reservations (approval queue, cancel), services
(availability rules, named units, trash) and the self-service policy.

- **Depends on:** `phoenix_kit` `~> 2.14` (Hex; the floor is functional, see
  Conventions → Time frame), `phoenix_live_calendar` `~> 0.4` (hard; the
  booking rules engine). Staff is read schemalessly, never depended on.
- **Consumed by:** nothing yet.
- **Admin surface:** `admin_tabs/0` registers `Bookings` (`/admin/bookings`,
  parent, redirects to its first subtab) with `Reservations`
  (`/admin/bookings/reservations`), `Services` (`/admin/bookings/services`)
  and two hidden leaves for the service form
  (`/admin/bookings/services/new`, `/admin/bookings/services/:uuid/edit`);
  `settings_tabs/0` registers `Bookings` under Admin → Settings
  (`/admin/settings/bookings`). Public routes from `route_module/0`:
  `/bookings`, `/book/:slug`, `/bookings/manage/:token`.
- **Module key** `"bookings"`; settings prefix `bookings_`.

## What this module does NOT do

- No payment collection. Prices and totals are stamped on every booking so a
  billing checkout can plug into `create_booking`'s success path; whether that
  is pay-at-booking, deposit or invoice-later is a product decision pending.
- No external calendar sync (Google/Outlook OAuth); the `.ics` attachment on
  confirmation emails covers the import case.
- No recurring bookings; the data-model choice (series table vs rrule) is
  undecided.
- No viewer-timezone display: everything renders in the site frame, because
  v1 services are physical venues.
- No customer-side unit choice; units are auto-assigned.
- No booking-rules engine of its own. `phoenix_live_calendar` owns
  `BookingConfig` / `Availability` / `Constraints.validate_booking` /
  `TimeSlots.bookable_slots`; `Engine` only maps rows onto lib structs. Do not
  rebuild any of it here.
- No compile-time reference to `phoenix_kit_staff`: a provider is a loose
  uuid and the admin select reads `phoenix_kit_staff_people` schemalessly
  behind a `to_regclass` guard.

## Commands

```bash
mix deps.get
createdb phoenix_kit_bookings_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
PHOENIX_LIVE_CALENDAR_PATH=../phoenix_live_calendar mix test
```

## Conventions

- Module key `"bookings"`; tab ids `:admin_bookings*` and
  `:admin_settings_bookings`; URL segments `bookings`, `book`, `manage`
  (hyphens, never underscores); activity actions `bookings.<noun>_<verb>`.
- Paths: `PhoenixKitBookings.Paths` holds every path this module navigates
  to, all through `PhoenixKit.Utils.Routes.path/1`; `*_url/1` helpers give
  absolute links for emails. Never hardcode a path.
- Routing: admin pages ride `live_view:` on `admin_tabs/0` /
  `settings_tabs/0`; the static `/new` tab is listed before the `:uuid`
  wildcard so generation order cannot let the wildcard shadow it. Public
  pages come from `route_module/0` → `Web.Routes.generate/1`, one
  `live_session :phoenix_kit_bookings_public` with core's permissive
  `:phoenix_kit_mount_current_scope` hook (logged-in scope when present,
  guest scope otherwise); `public_routes/1` returns nil. Never hand-register
  these in a host router.
- LiveView macro: `use PhoenixKitWeb, :live_view` in all eight LiveViews;
  `Web.Public.BookingFlow` is `use Phoenix.Component` + `import
  Phoenix.LiveView`. The routed public pages (`BookLive`, `ManageLive`,
  `Public.ServicesLive`) wrap in `LayoutWrapper.app_layout`; admin LVs and
  the widget never do.
- Gettext: the LiveViews use core's `PhoenixKitWeb.Gettext` (imported by the
  macro). `Errors` uses the module's own `PhoenixKitBookings.Gettext`
  backend, which has no `priv/gettext` catalogue, so engine messages render
  in English everywhere. Every call is macro-form `gettext/1,2`, so
  `mix gettext.extract` sees all of them.
- JS hooks: none. If one is ever needed, ship it in a prebuilt bundle
  declared by `js_sources/0` under a namespaced global, never from an inline
  `<script>` (morphdom does not execute inserted script tags, so an inline
  hook vanishes on LiveView navigation).
- `enabled?/0` reads `bookings_enabled`, rescues, catches `:exit` and returns
  `false`. `Policy.user_services_enabled?/0` and `max_services_per_user/0`
  do the same with their defaults.
- Activity logging: `PhoenixKitBookings.Activity.log/2` wraps
  `PhoenixKit.Activity.log/1` (module `"bookings"`, `Code.ensure_loaded?/1`
  guard, swallows Postgrex / ownership errors, never crashes the caller).
  The actor travels as `opts[:actor_uuid]` from `Policy` into the contexts;
  `Activity.actor_uuid/1` reads it from socket assigns. Metadata carries the
  service name or `service_uuid` + `status`, never customer fields.
- Soft-delete: `Service.status = "trashed"`. `Services.list_services/1`
  hides trashed rows unless `include_trashed: true` or `status: "trashed"`;
  permanent delete is the Trash view only and cascades to rules, units,
  holds, waitlist and bookings (`ON DELETE CASCADE`).
- Ownership fields are stamped, never cast: `Service.owner_uuid` from
  `opts[:owner_uuid]`, `service_uuid` on rules and units from the parent,
  and on bookings the time fields, `service_uuid`, `user_uuid`, `status`,
  `source` and `time_zone` (`Booking.stamp_changeset/4`). The customer
  changeset casts only what a customer types. `provider_uuid` is cast
  normally; it is admin input, not ownership.

### Booking model

- One booking model, three shapes (the Checkfront / Planyo / Mews pattern:
  one record type, behaviour driven by per-resource config). A booking row
  is EITHER `starts_at`/`ends_at` (UTC, minute services) OR
  `starts_on`/`ends_on` (DATE, day/night services) under the
  `bookings_time_shape` CHECK; holds carry the same either/or CHECK. Both
  pairs are exclusive-end. Check-in/out clock times are service ATTRIBUTES
  and never enter availability math.
- `Bookings.create_booking/4` is the race-proof choke point: it re-validates
  inside a transaction holding `FOR UPDATE` on the service row, and when a
  provider is attached on ALL that provider's services in uuid order
  (deadlock-safe). The pure `Engine.validate_request/5` call in the public
  flow is advisory UX only.
- Lifecycle `pending` (services with `require_approval`) → `confirmed` →
  `cancelled`. Pending bookings HOLD capacity; cancelled rows keep their
  times but stop counting.

### Engine adapter

- `overlap: seats > 1` on mapped events: with one seat the event must BLOCK
  (`validate_no_overlap` rejects only `overlap: false`); with pooled seats
  events must pass overlap and be COUNTED by capacity.
- Events are pre-expanded by the service buffers because the lib buffers
  only the REQUEST; expanded-vs-expanded means consecutive bookings need
  `buffer_after + buffer_before` of gap. The conflict window
  (`conflict_window/2` in `Bookings`, and the picker window in
  `BookingFlow.refresh_pick/1`) pads each side by BOTH buffers for the same
  reason. Shrinking it lets a booking just outside the raw range escape the
  reload; that is a real double-booking.
- Provider cross-service conflicts use `Engine.blocking_events/2`: absolute
  (`overlap: false`), no buffer expansion, minute services only.
- Unbounded duration (`max_duration: nil` + `flexible_duration`) maps to
  `@unbounded_minutes` (366 days) because the lib treats nil as "same as
  duration"; the availability window still bounds the real fit.
- A service with no rules is always open (a synthetic full-day window keeps
  slot generation and validation consistent).

### Time frame

- Minute-unit math runs in the SITE frame: the wall clock of core's
  `"time_zone"` setting (an IANA id, or a legacy fixed offset on a site that
  never touched the picker), UTC-tagged so the lib's minute arithmetic never
  sees a zone. Slots show and validate in venue-local time regardless of the
  viewer (the Cal.com `lockTimeZoneToggleOnBookingPage` behaviour).
- Storage is true UTC via `Engine.frame_to_utc` / `utc_to_frame`
  (`to_frame/2`, `from_frame/2,3` for an explicit zone). Both resolve the
  zone AT THE INSTANT CONVERTED through core's `Utils.Date.shift_to_offset/2`
  and `parse_datetime_local/2`. Never turn the setting into one number and
  add it: a scalar offset is an hour off across every daylight-saving switch
  and plain UTC on IANA sites. This is why the core pin is `~> 2.14`: those
  helpers are per-instant only from 2.14.1, and below it the frame silently
  collapses to UTC without raising. `test/core_pin_conformance_test.exs`
  guards the pin; keep it two-segment (`~> 2.14.0` would exclude every later
  core minor and break `mix deps.get` in hosts).
- `Engine.site_tz/0` is a settings query. Operations that convert many
  values (`validate_request/5`, `bookable_slots/5`) read it once and pass it
  down; `utc_to_frame/1` re-reads per call.
- Two Sundays a year a day is not 24 hours long, and the lib's grid is built
  from minutes. `Engine.frame_span_intact?/5` refuses a span whose wall
  clocks resolve to instants a different distance apart. Every path that
  turns a wall clock into a range must call it: `bookable_slots/5` marks such
  slots `:unavailable`, and BOTH public pickers (`pick_slot`, `pick_free`)
  check it before building a range, because a free-form service renders no
  grid and `pick_slot`'s params come from the client.
- Timed bookings stamp `time_zone` (the site's zone value at booking time) so
  their wall clock can be re-resolved later. Day/night services use bare
  dates and no tz math ever.
- Tests pass the zone explicitly and use IANA values from BOTH seasons
  (`Europe/Tallinn` in July and November, plus the spring-forward and
  fall-back Sundays); a fixed-offset-only test proves nothing.

### Permissions and self-service

- Core's sub-implies-base semantics force the orientation: base `bookings`
  = the admin area scoped to OWNED services (`owner_uuid`; nil = site
  service); sub `bookings.manage_all` = every service, every reservation and
  the settings page. Owner/superadmin roles hold it implicitly.
- `Policy` is the only authorization surface. Admin LVs route every read
  (`visible_services/2`, `visible_service_uuids/1`) and every mutation
  through it, never `Services` / `Bookings` directly; buttons are hidden AND
  actions re-checked. Managers create SITE services (no owner); base holders
  create services owned by themselves, only when
  `bookings_user_services_enabled` is on and they are under
  `bookings_max_services_per_user`.
- Customer self-cancel: `Bookings.cancellable_by_customer?/2` gates
  `ManageLive`, re-checked server-side on the event, not just button-hiding.
  Admins cancel unrestricted.

### Public flow

- Embeddable LiveViews must not export `handle_params/3` (Phoenix refuses to
  mount one outside a router live route). Hence the `BookLive` /
  `BookingWidgetLive` split with all logic in `BookingFlow`: both delegate
  `handle_event/3` + `handle_info/2` there and call
  `BookingFlow.on_terminate/1` from `terminate/2`. `live_render` skips router
  `on_mount` hooks, so the host passes the viewer through the session.
- Holds: `create_hold/3` runs after the advisory validation passes (5-minute
  TTL). `list_occupancy/3` maps unexpired holds to pseudo-bookings so EVERY
  capacity read (picker, advisory, locked create) sees them; expired rows
  are ignored and lazily pruned inside the locked create; the flow's own
  hold is excluded via `exclude_hold:` and consumed on success; it is
  released on `terminate/2`, Back, and before a new pick.
- Manage tokens: `Phoenix.Token` signed against the HOST endpoint. The
  resolution order is explicit `config :phoenix_kit, endpoint:` (tests) →
  core's `Config.get_parent_endpoint/0` (host apps) →
  `PhoenixKitWeb.Endpoint`. Core's own endpoint is compiled but not running
  in a host; signing against it crashes on the ETS lookup. Salt
  `phoenix_kit_bookings.manage`, max age 90 days.

### Capacity, providers, pricing, email, waitlist

- Named units (`Schemas.Unit`): capacity = active-unit count when any exist,
  else pooled `seats` (`Services.effective_seats/1`); `pick_unit` assigns
  the first free unit by name inside the locked create. Legacy nil-unit
  bookings consume capacity without a unit. Deleting a unit keeps its past
  bookings (`ON DELETE SET NULL`).
- Providers: `service.provider_uuid` is a loose staff reference (no FK).
- Pricing (`Pricing.total/2`): `price × price_per` units, stamped inside the
  create; a `price_per` that does not fit the range shape degrades to the
  flat price; unpriced services carry no total.
- Email (`Notifier` + `ICS`): every send goes through `PhoenixKit.Mailer`
  and is best-effort (rescue + log; a mail failure never fails the
  operation). Confirmations attach an `.ics`. `Workers.ReminderWorker`
  (Oban, `:default` queue) is scheduled at creation for
  `starts_at - reminder_minutes` and re-checks state at fire time, so
  cancellations need no job bookkeeping; day-mode bookings, past reminder
  moments and a missing Oban all no-op.
- Waitlist (`Schemas.WaitlistEntry`): join is idempotent per
  service+email+date; a cancellation notifies every open entry for the freed
  dates (notify-all, first-to-book) and flips them to `notified`.
- Cancellation windows: `cancel_notice` minutes before start; day-mode
  rounds up to whole days.

### Landmines

- `config/test.exs` defaults `PGUSER` to `postgres`. On a machine without
  that role (the Mac's brew Postgres uses `maxdon`) the DB probe fails and
  the whole `:integration` set is excluded behind a banner while the run
  stays green; export `PGUSER` and check the banner is absent.
- `Swoosh.TestAssertions.assert_email_sent` pops the mailbox IN ORDER:
  consume the confirmation before asserting the cancellation or reminder.
- `Scope.can?/2` gates on module enablement, so `bookings_enabled` must be
  set BEFORE sandbox mode (`test_helper.exs` does it); otherwise every
  Policy check fails closed suite-wide and admin LV tests redirect.
- The public LVs render through `LayoutWrapper.app_layout`; its fallback
  (core's root layout) calls `PhoenixKitWeb.Endpoint.static_path/1` on an
  endpoint that is not started in module tests. `config :phoenix_kit,
  layout:` must keep pointing at `Test.Layouts.public`.
- `Engine.from_frame/3` degrades an unresolvable zone value to UTC silently;
  a zone typo in a test fixture passes as a UTC site.

## Architecture

```
lib/phoenix_kit_bookings.ex             PhoenixKit.Module: tabs, settings tab, permissions, route_module, migration_module
lib/phoenix_kit_bookings/
  schemas/service.ex                    one bookable offer; the WHOLE booking shape is per-service
  schemas/availability_rule.ex          weekly rule | date override | block-out (maps 1:1 to lib Availability)
  schemas/booking.ex                    timed pair OR date pair, exclusive ends
  schemas/unit.ex                       named unit (room, chair) of a service
  schemas/hold.ex                       5-minute slot hold, same either/or time CHECK
  schemas/waitlist_entry.ex             open | notified | removed, per service+email+date
  engine.ex                             adapter onto phoenix_live_calendar's booking layer + the site frame
  engine/day_engine.ex                  the date-granular path the lib does not cover (day/night)
  services.ex                           services, rules, units; activity + PubSub on every mutation
  bookings.ex                           create (locked), confirm, cancel, holds, waitlist, manage tokens
  policy.ex                             ALL admin authorization + self-service rules
  pricing.ex                            price × price_per units
  notifier.ex / ics.ex                  best-effort lifecycle email + .ics attachment
  workers/reminder_worker.ex            Oban reminder at starts_at - reminder_minutes
  activity.ex                           PhoenixKit.Activity wrapper
  errors.ex                             reason atom → user-facing message
  gettext.ex                            PhoenixKitBookings.Gettext backend (no catalogue yet)
  paths.ex                              every path, via Routes.path/1
  migrations/schema.ex                  module-owned chain
  web/routes.ex                         public routes (generate/1)
  web/format.ex                         range and date formatting in the site frame
  web/admin/{services,service_form,bookings,settings}_live.ex
  web/public/booking_flow.ex            shared state, events and markup of both booking LVs
  web/public/{book,booking_widget,manage,services}_live.ex
```

### Tables

All `phoenix_kit_bookings_*`, UUIDv7 primary keys, `use PhoenixKit.SchemaPrefix`.

| Table | Purpose | Constraints worth knowing |
|---|---|---|
| `services` | the bookable offer (shape, buffers, notice, seats, stay bounds, `signup_policy`, `require_approval`, `owner_uuid`, `cancel_notice`, `provider_uuid`, `price`/`price_per`/`currency`, `reminder_minutes`, `settings` JSONB) | unique `slug`; status `active` / `inactive` / `trashed`; `price_per` in `booking` / `hour` / `day` / `night`; `owner_uuid` FK to users `ON DELETE SET NULL` |
| `availability_rules` | weekly rule (`days_of_week`), date override (`date`), `available: false` = block-out; times only for minute services | cascade from service |
| `units` | named units, `active` flag | cascade from service |
| `holds` | timed or dated range + `expires_at` | `bookings_hold_time_shape` |
| `waitlist` | `date`, customer name/email, status `open` / `notified` / `removed` | cascade from service |
| `bookings` | timed or dated range, `time_zone`, customer fields, `user_uuid`, `unit_uuid` (`SET NULL`), `total_price`/`currency`, `source` `public` / `admin`, cancellation stamp, `metadata` JSONB | `bookings_time_shape`, `bookings_timed_order`, `bookings_dated_order`, status `pending` / `confirmed` / `cancelled` |

### PubSub

Broadcast on the host PubSub (`PhoenixKit.Config.pubsub_server/0`); a
missing server or a failed broadcast is a no-op.

| Topic | Message | Subscribers |
|---|---|---|
| `phoenix_kit_bookings:bookings` (`Bookings.admin_topic/0`) | `{:bookings_changed, service_uuid}` | admin `BookingsLive` |
| `phoenix_kit_bookings:service:<uuid>` (`Bookings.service_topic/1`) | `{:bookings_changed, service_uuid}` on every booking mutation and every new hold | the public flows (exactly one topic each) |
| `phoenix_kit_bookings:services` (`Services.services_topic/0`) | `{:bookings_service_changed, service_uuid}` on every service, rule and unit mutation | admin `ServicesLive` |

### Settings

| Key | Type | Default | Meaning |
|---|---|---|---|
| `bookings_enabled` | boolean | `false` | module on/off |
| `bookings_user_services_enabled` | boolean | `false` | base-permission holders may CREATE services (off: they still manage services assigned to them) |
| `bookings_max_services_per_user` | integer | `1` | per-user creation cap; `0` = unlimited |

Core settings read: `"time_zone"` (the site frame), `"from_email"` /
`"from_name"` (Notifier).

### Permissions

`bookings` (base: own services) with sub-permission `bookings.manage_all`
(site-wide + settings page). Declared by `permission_metadata/0`.

### Activity actions

`bookings.service_created`, `service_updated`, `service_status_changed`,
`service_trashed`, `service_restored`, `service_deleted`,
`availability_rule_added`, `availability_rule_removed`, `unit_added`,
`unit_updated`, `unit_removed` (resource `bookings_service`) and
`bookings.booking_created`, `booking_confirmed`, `booking_cancelled`
(resource `booking`).

### Widget session contract (host → `live_render/3`)

| Session key | Required | Meaning |
|---|---|---|
| `"slug"` | yes | active service slug; unknown slug renders the "not taking bookings" notice |
| `"current_user_uuid"` | no | resolved via `PhoenixKit.Users.Auth.get_user/1`; enables `login_required` services and prefill |
| `"prefill"` | no | map with `"customer_name"` / `"customer_email"` |
| `"wrapper_class"` | no | class on the outer `<div>` |

### Error vocabulary

`Errors.message/2` maps every reason atom the engine, `DayEngine` and the
contexts return (`:invalid_range`, `:too_short`, `:too_long`, `:in_past`,
`:insufficient_notice`, `:too_far_ahead`, `:outside_availability`,
`:overlap`, `:at_capacity`, `:login_required`, `:service_unavailable`,
`:not_cancellable`, `:cancel_window_passed`, `:invalid_waitlist`) to a
user-facing string; LiveViews never show a raw atom or engine string.

## Database & migrations

Owns a versioned chain: `PhoenixKitBookings.Migrations.Schema` via
`migration_module/0`, marker `bookings_schema:<N>` as a COMMENT ON
`phoenix_kit_bookings_services`, currently V2. `mix phoenix_kit.update`
applies it in hosts; tests run it via `Ecto.Migrator.run` over the
`Test.SchemaMigration` (V1) and `Test.SchemaMigrationV2` wrappers in
`test_helper.exs`.

- `up/1` is one idempotent pass: every statement is `IF NOT EXISTS` /
  `ADD COLUMN IF NOT EXISTS`, and the marker is stamped last, after every
  statement it certifies. Replaying it on a V1 database adds only what V2
  adds.
- `migrated_version_runtime/1` reads the marker; a marker-less services
  table reads as 1 (it predates the marker), a missing table as 0.
- `down/1` with `version: 1` drops only the V2 column and restamps;
  `version: 0` (the default) drops all six tables.
- `opts[:prefix]` is validated as an identifier (`ArgumentError` otherwise)
  before interpolation, and `uuid_generate_v7()` is always schema-qualified:
  a bare call breaks every `--prefix` install and works everywhere else.
  `schema_prefix_conformance_test.exs` greps for both.
- V1 and V2 are released and immutable. A shape change is V3: add its
  statements to `up/1`, bump `@current_version`, extend `down/1`, mirror the
  V2 wrapper for the test chain, and extend `migrations_test.exs`.

UUIDv7 primary keys; `use PhoenixKit.SchemaPrefix` on every table-backed
schema (the conformance test enforces it).

## Testing

- Test DB `phoenix_kit_bookings_test` (`MIX_TEST_PARTITION` suffix
  honoured). `mix test.setup` creates it, `mix test.reset` drops and
  recreates it. `config/test.exs` honours `PGUSER` (default `postgres`),
  `PGPASSWORD`, `PGHOST`.
- Without Postgres: `engine_test.exs` (Engine + DayEngine, pure),
  `core_pin_conformance_test.exs`, `schema_prefix_conformance_test.exs`,
  `phoenix_kit_bookings_test.exs`. Everything on `DataCase` / `LiveCase` is
  `:integration` and excluded when `test_helper.exs`'s `psql -lqt` probe or
  `Repo.start_link` fails (a banner says so).
- Schema build in `test_helper.exs`: `PhoenixKit.Migration.ensure_current/2`
  for core's tables, then the module chain via `Ecto.Migrator.run` (`{1,
  Test.SchemaMigration}`, `{2, Test.SchemaMigrationV2}`), then
  `bookings_enabled` set BEFORE `Sandbox.mode(:manual)`.
  `PhoenixKit.PubSub.Manager` and `PhoenixKit.ModuleRegistry` are started,
  the URL-prefix persistent term is forced to `"/"`, and `Test.Endpoint`
  starts only when the DB is available.
- Support modules: `DataCase` (sandbox owner, `errors_on/1`, imports
  `Fixtures`); `LiveCase` (`@endpoint Test.Endpoint`, `fake_scope/1`
  defaulting to a site-wide admin `["bookings", "bookings.manage_all"]`,
  pass `permissions: ["bookings"]` for an own-services-only user;
  `put_test_scope/2` stores it under session key `"phoenix_kit_test_scope"`,
  which `Test.Hooks.on_mount(:assign_scope)` turns into
  `phoenix_kit_current_scope` / `phoenix_kit_current_user`); `Test.Router`
  (admin under `/en/admin/...`, public bare, matching `Paths`);
  `Test.Layouts` (`:root`, `:app` with `#flash-info` / `#flash-error` /
  `#flash-warning`, `:public` as the `config :phoenix_kit, layout:` target,
  `render/2` catching error templates); `Fixtures` (`slot_service_fixture`,
  `freeform_service_fixture`, `hotel_service_fixture`,
  `business_hours_rule_fixture`, `customer_attrs`, `next_weekday`; names
  are uniquified per call so a default row cannot mask a wrong-service
  fallback).
- `config :phoenix_kit` wires `repo:`, `endpoint:` (token signing) and
  `layout:`; `PhoenixKit.Mailer` runs on `Swoosh.Adapters.Test`, so assert
  mail with `Swoosh.TestAssertions`.
- `create_booking/4` accepts `:now` / `:today` for time injection; engine
  functions take the zone as their last argument for the same reason.
- Known noise, not failures: a "redefining module" warning per
  `test/support` module (`elixirc_paths(:test)` compiles the directory AND
  `test_helper.exs` `Code.require_file`s the same files), and
  `Phoenix.LiveViewTest` `missing_form_id` warnings from
  `public_live_test.exs` (the booking forms carry no `id`). No known flakes.

## Feature notes

None. Feature behaviour lives in the `@moduledoc`s (`Engine`, `Bookings`,
`Policy`, `BookingFlow`, `Migrations.Schema`, `BookingWidgetLive`). The
product survey behind the one-model/three-shapes decision and the list of
what `phoenix_live_calendar` already covers is
`dev_docs/research/2026-07-24-booking-module-research.md`.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- Payment collection: product decision pending (pay-at-booking vs deposit vs
  invoice-later). Totals are already stored; billing plugs into
  `create_booking`'s success path once decided.
- External calendar sync (Google/Outlook OAuth): blocked on provider
  credentials.
- Recurring bookings: pick the data model (series table vs rrule) before
  building.
- Viewer-timezone slot display: unblocks when a service is not a physical
  venue (virtual services).
- Per-date (seasonal) pricing rules and customer-chosen named units:
  unblocks on a product request.
- A `priv/gettext` catalogue for `PhoenixKitBookings.Gettext` (or moving
  `Errors` onto core's backend): unblocks on the first translation pass.
- Retire `@unbounded_minutes` when `phoenix_live_calendar` ships an explicit
  unbounded-duration semantic.
