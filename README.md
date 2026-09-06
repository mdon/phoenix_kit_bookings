# PhoenixKitBookings

Universal booking module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

One install runs any mix of booking shapes — the shape is **per-service
configuration**, never a module-level setting:

| Archetype | Config | Example |
|---|---|---|
| **Day / night stays** | `time_unit: night` (or `day`), pooled `seats` inventory, min/max stay, check-in/out times | A hotel room type with 7 rooms |
| **Fixed slots** | `time_unit: minutes`, `duration` + `slot_interval` grid | A massage parlor booked on the hour, for an hour |
| **Free-form** | `flexible_duration`, `min_duration`, `max_duration` (blank = unlimited) | A gym floor booked from any time, for any length |

All three coexist in one install (a hotel that also offers massages), share
one admin, one public surface, and one `bookings` table.

## Features

- **Rules engine** from [`phoenix_live_calendar`](https://hex.pm/packages/phoenix_live_calendar)'s
  booking layer: availability windows (weekly rules + date overrides +
  block-outs), buffers, minimum notice, booking window, per-slot/per-date
  pooled capacity, cross-midnight-correct validation.
- **Race-proof creation** — requests re-validate inside a `FOR UPDATE`
  transaction on the service row; the last seat can only be taken once.
- **Live everywhere** — every mutation broadcasts on per-service and admin
  PubSub topics; public pickers grey out a just-taken slot in real time and
  admin lists refresh across sessions.
- **Public booking pages** (`/bookings`, `/book/:slug`) with guest booking,
  per-service signup policy (`anyone` / `login_required`), optional
  approval flow (`require_approval` → pending, RSVP-style), and tokenized
  guest self-service (`/bookings/manage/:token` — view + cancel, no
  account needed).
- **Embeddable widget** — `PhoenixKitBookings.Web.Public.BookingWidgetLive`
  mounts on any host page via `live_render/3` (see its moduledoc for the
  session contract).
- **Named units** — optionally name the individual rooms/chairs/courts;
  capacity becomes the active-unit count and every booking is
  auto-assigned a free unit (pooled counting stays the default — the
  Booqable `trackable` dichotomy, per service).
- **Slot holds** — advancing to the details form reserves the picked
  range for 5 minutes (Cal.com `SelectedSlots` pattern); rivals see it
  taken, expiry is lazy, the locked create still decides.
- **Providers** — attach a staff person to a service; their bookings
  block each other ACROSS services (a therapist can't be double-booked
  between "Massage" and "Consultation").
- **Pricing** — per-service price per booking/hour/day/night; totals are
  computed and stored on each booking and shown everywhere. Payment
  collection (billing checkout) is deliberately not wired yet.
- **Emails** — confirmation (with `.ics` calendar attachment + manage
  link), approval, cancellation, and Oban-scheduled reminder emails, all
  best-effort via core's mailer.
- **Waitlist** — full dates offer a join form; a cancellation emails
  every open entry for the freed dates (notify-all, first-to-book).
- **Cancellation windows** — per-service `cancel_notice` gates guest
  self-cancellation; admins are never blocked.
- **Ownership + permissions** — base `bookings` permission scopes the
  admin area to services the user OWNS; `bookings.manage_all` is
  site-wide. Owner-controlled self-service settings: whether users may
  create their own services and how many (`0` = unlimited).
- **Admin** — Reservations (filter tabs, approval queue, cancel), Services
  (mode-aware form, availability rules + named-units editors, soft-delete
  trash), and a Settings page for the self-service policy.

## Installation

```elixir
# mix.exs of your PhoenixKit host app
{:phoenix_kit_bookings, "~> 0.1.3"}
```

Requires [`phoenix_kit`](https://hex.pm/packages/phoenix_kit) `~> 2.14`.
The floor is not cosmetic: the site time frame is built on
`PhoenixKit.Utils.Date.shift_to_offset/2` and `parse_datetime_local/2`,
which resolve a timezone per instant only from core 2.14.1 — below that
they answer `0` for every IANA id and every booking is silently stored
as UTC. Run `mix deps.get`, then `mix phoenix_kit.update` — the module
owns its versioned migration (`PhoenixKitBookings.Migrations.Schema`,
discovered via `migration_module/0`). Enable **Bookings** on the admin
Modules page.

## Development

```bash
mix test.setup   # createdb phoenix_kit_bookings_test + migrations
mix test         # 105 tests; :integration auto-excluded without a DB
mix precommit    # compile --warnings-as-errors, credo --strict, dialyzer
```

Cross-repo work against local checkouts: `PHOENIX_KIT_PATH=../phoenix_kit`
and/or `PHOENIX_LIVE_CALENDAR_PATH=../phoenix_live_calendar` (unset = the
published Hex pins). See `AGENTS.md` for architecture notes.
