defmodule PhoenixKitBookingsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The `PhoenixKit.Module` behaviour surface core discovers by `.beam`
  scanning. No database: everything here is a constant.
  """

  test "identifies itself to core" do
    assert PhoenixKitBookings.module_key() == "bookings"
    assert PhoenixKitBookings.module_name() == "Bookings"
    assert PhoenixKitBookings.migration_module() == PhoenixKitBookings.Migrations.Schema
    assert PhoenixKitBookings.route_module() == PhoenixKitBookings.Web.Routes
    assert PhoenixKitBookings.css_sources() == [:phoenix_kit_bookings]
  end

  test "version is single-sourced from mix.exs" do
    assert PhoenixKitBookings.version() == Mix.Project.config()[:version]
  end

  test "the permission model is base = own services, sub = manage_all" do
    %{key: "bookings", sub_permissions: [%{key: "manage_all"}]} =
      PhoenixKitBookings.permission_metadata()
  end
end
