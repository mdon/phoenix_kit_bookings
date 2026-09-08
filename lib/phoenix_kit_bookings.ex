defmodule PhoenixKitBookings do
  @moduledoc """
  PhoenixKit plugin module for universal bookings.

  One install can mix bookable services with entirely different shapes —
  the booking mode is per-service configuration, never a module setting:

  - **Day / night** (`time_unit: "day" | "night"`) — hotel-style date-range
    stays with pooled room inventory (`seats`), min/max stay, blackout
    dates, check-in/check-out display times.
  - **Fixed slots** (`time_unit: "minutes"`, `flexible_duration: false`) —
    massage-parlor-style slot grids (`duration` + `slot_interval`).
  - **Free-form** (`flexible_duration: true`) — gym-style "pick any start,
    any length" with `min_duration`/`max_duration` (`nil` = unbounded).

  The slot/validation engine is `phoenix_live_calendar`'s booking layer
  (`BookingConfig` / `Availability` / `Constraints` / `TimeSlots`), adapted
  in `PhoenixKitBookings.Engine`; the date-granular path lives in
  `PhoenixKitBookings.Engine.DayEngine`. Creation is race-proof — see
  `PhoenixKitBookings.Bookings`.

  ## How it works

  1. `use PhoenixKit.Module` marks this module as a plugin.
  2. PhoenixKit discovers it by `.beam` scanning — no config line needed.
  3. `migration_module/0` points at `PhoenixKitBookings.Migrations.Schema`;
     `mix phoenix_kit.update` creates the three tables — no core PR needed.
  4. Admin pages ride on `admin_tabs/0`; the public booking pages
     (`/bookings`, `/book/:slug`, `/bookings/manage/:token`) come from
     `PhoenixKitBookings.Web.Routes.generate/1`.

  ## Installation

  Add to your parent app's `mix.exs`:

      {:phoenix_kit_bookings, "~> 0.1.3"}

  Run `mix deps.get`, then `mix phoenix_kit.update` to create the tables.
  The module appears in the admin sidebar and Modules page automatically.

  ## Embedding

  `PhoenixKitBookings.Web.Public.BookingWidgetLive` is embeddable via
  `live_render/3` on any host page — see its moduledoc for the session
  contract.
  """

  use PhoenixKit.Module

  @version Mix.Project.config()[:version]

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  @doc "Unique key for this module. Used in settings, permissions, and PubSub events."
  def module_key, do: "bookings"

  @impl PhoenixKit.Module
  @doc "Display name shown in the admin UI."
  def module_name, do: "Bookings"

  @impl PhoenixKit.Module
  @doc """
  Whether the module is currently enabled.

  Reads from the DB-backed settings table. Defensive against DB not being
  available yet (startup ordering, missing table, sandbox artifacts in
  tests) — always falls back to `false`.
  """
  def enabled? do
    Settings.get_boolean_setting("bookings_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  @doc "Enables the module by persisting a boolean setting."
  def enable_system do
    Settings.update_boolean_setting_with_module("bookings_enabled", true, module_key())
  end

  @impl PhoenixKit.Module
  @doc "Disables the module. Same pattern as `enable_system/0`."
  def disable_system do
    Settings.update_boolean_setting_with_module("bookings_enabled", false, module_key())
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  @doc "Version string, single-sourced from `mix.exs` at compile time."
  def version, do: @version

  @impl PhoenixKit.Module
  @doc """
  Permission metadata. Calendar-module orientation (a sub implies its
  base, so the base must be the NARROW capability): the base key grants
  the bookings admin area scoped to services the user OWNS — the key an
  owner hands out for self-service; `bookings.manage_all` is site-wide
  management + module settings.
  """
  def permission_metadata do
    %{
      key: module_key(),
      label: "Bookings",
      icon: "hero-ticket",
      description:
        "Universal booking management — day/night stays, fixed slots, and free-form " <>
          "reservations. The base permission covers only services the user owns.",
      sub_permissions: [
        %{
          key: "manage_all",
          label: "Manage all bookings",
          description:
            "Site-wide: every service and reservation (not just own), plus the Bookings settings page"
        }
      ]
    }
  end

  @impl PhoenixKit.Module
  @doc """
  Admin sidebar tabs: a parent tab plus visible Reservations + Services
  lists and hidden leaf tabs for the service form. Static `/new` is
  ordered before the `:uuid` wildcard tab so route generation (list
  order) doesn't let the wildcard shadow it.
  """
  def admin_tabs do
    [
      %Tab{
        id: :admin_bookings,
        label: "Bookings",
        icon: "hero-ticket",
        path: "bookings",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        redirect_to_first_subtab: true,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      %Tab{
        id: :admin_bookings_reservations,
        label: "Reservations",
        icon: "hero-clipboard-document-list",
        path: "bookings/reservations",
        priority: 651,
        level: :admin,
        permission: module_key(),
        parent: :admin_bookings,
        live_view: {PhoenixKitBookings.Web.Admin.BookingsLive, :index}
      },
      %Tab{
        id: :admin_bookings_services,
        label: "Services",
        icon: "hero-rectangle-stack",
        path: "bookings/services",
        priority: 652,
        level: :admin,
        permission: module_key(),
        parent: :admin_bookings,
        live_view: {PhoenixKitBookings.Web.Admin.ServicesLive, :index}
      },
      %Tab{
        id: :admin_bookings_service_new,
        label: "New Service",
        path: "bookings/services/new",
        priority: 653,
        level: :admin,
        permission: module_key(),
        parent: :admin_bookings_services,
        visible: false,
        live_view: {PhoenixKitBookings.Web.Admin.ServiceFormLive, :new}
      },
      %Tab{
        id: :admin_bookings_service_edit,
        label: "Edit Service",
        path: "bookings/services/:uuid/edit",
        priority: 654,
        level: :admin,
        permission: module_key(),
        parent: :admin_bookings_services,
        visible: false,
        live_view: {PhoenixKitBookings.Web.Admin.ServiceFormLive, :edit}
      }
    ]
  end

  @impl PhoenixKit.Module
  @doc "Settings page (self-service policy) under Admin → Settings."
  def settings_tabs do
    [
      %Tab{
        id: :admin_settings_bookings,
        label: "Bookings",
        icon: "hero-ticket",
        path: "bookings",
        priority: 650,
        level: :admin,
        permission: module_key(),
        parent: :admin_settings,
        live_view: {PhoenixKitBookings.Web.Admin.SettingsLive, :index}
      }
    ]
  end

  @impl PhoenixKit.Module
  @doc "OTP apps whose templates Tailwind should scan for CSS classes."
  def css_sources, do: [:phoenix_kit_bookings]

  @impl PhoenixKit.Module
  @doc "Public booking routes (the admin pages ride on `admin_tabs/0`)."
  def route_module, do: PhoenixKitBookings.Web.Routes

  @impl PhoenixKit.Module
  @doc """
  Versioned migration coordinator for the bookings tables. Picked up
  automatically by `mix phoenix_kit.update` — the tables are not part of
  core `phoenix_kit`'s own migration chain.
  """
  def migration_module, do: PhoenixKitBookings.Migrations.Schema
end
