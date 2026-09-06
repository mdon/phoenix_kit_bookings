defmodule PhoenixKitBookings.BookingsTest do
  use PhoenixKitBookings.DataCase, async: true

  alias Ecto.Adapters.SQL
  alias PhoenixKitBookings.{Bookings, Services}

  # Site frame == UTC in tests (no time_zone setting), so frame math is
  # transparent here.
  defp tomorrow_at(hour) do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp future_date(days), do: Date.add(Date.utc_today(), days)

  describe "create_booking/4 — fixed slots (massage archetype)" do
    test "books an open slot and blocks the double-book" do
      service = slot_service_fixture()

      {:ok, booking} =
        Bookings.create_booking(
          service,
          {tomorrow_at(10), tomorrow_at(11)},
          customer_attrs()
        )

      assert booking.status == "confirmed"
      assert booking.starts_at
      refute booking.starts_on
      # a timed booking remembers the site's zone it was made in
      assert booking.time_zone == PhoenixKitBookings.Engine.site_tz()

      assert {:error, :overlap, _} =
               Bookings.create_booking(
                 service,
                 {tomorrow_at(10), tomorrow_at(11)},
                 customer_attrs()
               )

      # An adjacent slot is fine (exclusive ends).
      assert {:ok, _} =
               Bookings.create_booking(
                 service,
                 {tomorrow_at(11), tomorrow_at(12)},
                 customer_attrs()
               )
    end

    test "cancelling frees the slot" do
      service = slot_service_fixture()
      range = {tomorrow_at(10), tomorrow_at(11)}

      {:ok, booking} = Bookings.create_booking(service, range, customer_attrs())
      {:ok, cancelled} = Bookings.cancel_booking(booking, reason: "test")
      assert cancelled.status == "cancelled"
      assert cancelled.cancelled_at

      assert {:ok, _} = Bookings.create_booking(service, range, customer_attrs())
    end

    test "buffers block adjacent slots" do
      service = slot_service_fixture(%{"buffer_after" => 30})

      {:ok, _} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      assert {:error, :overlap, _} =
               Bookings.create_booking(
                 service,
                 {tomorrow_at(11), tomorrow_at(12)},
                 customer_attrs()
               )
    end

    test "availability rules reject out-of-hours bookings" do
      service = slot_service_fixture()
      business_hours_rule_fixture(service)

      # Next Monday 20:00 — outside Mon–Fri 09:00–17:00.
      monday = next_weekday(1)
      late = DateTime.new!(monday, ~T[20:00:00], "Etc/UTC")

      assert {:error, :outside_availability, _} =
               Bookings.create_booking(
                 service,
                 {late, DateTime.add(late, 3600, :second)},
                 customer_attrs()
               )

      # Next Sunday is closed entirely (no weekly rule covers it).
      sunday = next_weekday(7)
      morning = DateTime.new!(sunday, ~T[10:00:00], "Etc/UTC")

      assert {:error, :outside_availability, _} =
               Bookings.create_booking(
                 service,
                 {morning, DateTime.add(morning, 3600, :second)},
                 customer_attrs()
               )
    end

    test "rejects invalid customer fields as a changeset" do
      service = slot_service_fixture()

      {:error, changeset} =
        Bookings.create_booking(
          service,
          {tomorrow_at(10), tomorrow_at(11)},
          %{"customer_name" => "X", "customer_email" => "not-an-email"}
        )

      assert %{customer_email: _} = errors_on(changeset)
    end

    test "rejects a date-range request against a minute service" do
      service = slot_service_fixture()

      assert {:error, :invalid_range, _} =
               Bookings.create_booking(
                 service,
                 {:dates, future_date(3), future_date(5)},
                 customer_attrs()
               )
    end
  end

  describe "create_booking/4 — free-form (gym archetype)" do
    test "books an arbitrary multi-hour range with no ceiling" do
      service = freeform_service_fixture()

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(6), tomorrow_at(14)}, customer_attrs())

      assert booking.status == "confirmed"
    end

    test "pooled seats: capacity counts overlapping bookings" do
      service = freeform_service_fixture(%{"seats" => 2})

      {:ok, _} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(12)}, customer_attrs())

      {:ok, _} =
        Bookings.create_booking(service, {tomorrow_at(11), tomorrow_at(13)}, customer_attrs())

      assert {:error, :at_capacity, _} =
               Bookings.create_booking(
                 service,
                 {tomorrow_at(11), tomorrow_at(12)},
                 customer_attrs()
               )

      # Outside the crowded window there is room.
      assert {:ok, _} =
               Bookings.create_booking(
                 service,
                 {tomorrow_at(14), tomorrow_at(15)},
                 customer_attrs()
               )
    end

    test "enforces the minimum duration" do
      service = freeform_service_fixture()

      too_short_end = DateTime.add(tomorrow_at(10), 10 * 60, :second)

      assert {:error, :too_short, _} =
               Bookings.create_booking(
                 service,
                 {tomorrow_at(10), too_short_end},
                 customer_attrs()
               )
    end
  end

  describe "create_booking/4 — nightly stays (hotel archetype)" do
    test "books a stay, fills the inventory, frees on cancel" do
      service = hotel_service_fixture()
      range = {:dates, future_date(7), future_date(9)}

      bookings =
        for _ <- 1..3 do
          {:ok, booking} = Bookings.create_booking(service, range, customer_attrs())
          # dates carry no zone
          assert booking.time_zone == nil
          booking
        end

      assert {:error, :at_capacity, _} =
               Bookings.create_booking(service, range, customer_attrs())

      {:ok, _} = Bookings.cancel_booking(hd(bookings))

      assert {:ok, _} = Bookings.create_booking(service, range, customer_attrs())
    end

    test "back-to-back stays share the changeover date (exclusive ends)" do
      service = hotel_service_fixture(%{"seats" => 1})

      {:ok, _} =
        Bookings.create_booking(
          service,
          {:dates, future_date(7), future_date(9)},
          customer_attrs()
        )

      assert {:ok, _} =
               Bookings.create_booking(
                 service,
                 {:dates, future_date(9), future_date(11)},
                 customer_attrs()
               )
    end

    test "min_stay and blackout dates are enforced" do
      service = hotel_service_fixture(%{"min_stay" => 2})

      assert {:error, :too_short, _} =
               Bookings.create_booking(
                 service,
                 {:dates, future_date(7), future_date(8)},
                 customer_attrs()
               )

      {:ok, _} =
        Services.add_rule(service, %{
          "date" => Date.to_iso8601(future_date(8)),
          "available" => false
        })

      assert {:error, :outside_availability, _} =
               Bookings.create_booking(
                 service,
                 {:dates, future_date(7), future_date(9)},
                 customer_attrs()
               )
    end
  end

  describe "policies and lifecycle" do
    test "login_required without a user is rejected on the public path" do
      service = slot_service_fixture(%{"signup_policy" => "login_required"})
      range = {tomorrow_at(10), tomorrow_at(11)}

      assert {:error, :login_required, _} =
               Bookings.create_booking(service, range, customer_attrs())

      assert {:ok, _} =
               Bookings.create_booking(service, range, customer_attrs(),
                 user_uuid: Ecto.UUID.generate() |> then(&create_user_uuid/1)
               )
    end

    test "require_approval starts pending, holds the seat, and confirms" do
      service = slot_service_fixture(%{"require_approval" => true})
      range = {tomorrow_at(10), tomorrow_at(11)}

      {:ok, pending} = Bookings.create_booking(service, range, customer_attrs())
      assert pending.status == "pending"

      # The pending request holds the slot.
      assert {:error, :overlap, _} = Bookings.create_booking(service, range, customer_attrs())

      {:ok, confirmed} = Bookings.confirm_booking(pending)
      assert confirmed.status == "confirmed"
    end

    test "admin source books an inactive service and skips approval" do
      service = slot_service_fixture(%{"require_approval" => true})
      {:ok, service} = Services.set_status(service, "inactive")
      range = {tomorrow_at(10), tomorrow_at(11)}

      assert {:error, :service_unavailable, _} =
               Bookings.create_booking(service, range, customer_attrs())

      {:ok, booking} =
        Bookings.create_booking(service, range, customer_attrs(), source: "admin")

      assert booking.status == "confirmed"
      assert booking.source == "admin"
    end

    test "cancelled bookings cannot be cancelled again" do
      service = slot_service_fixture()

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      {:ok, cancelled} = Bookings.cancel_booking(booking)

      assert {:error, :not_cancellable, _} = Bookings.cancel_booking(cancelled)
    end
  end

  describe "manage tokens" do
    test "round-trips and rejects garbage" do
      service = slot_service_fixture()

      {:ok, booking} =
        Bookings.create_booking(service, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      token = Bookings.manage_token(booking)
      assert %{uuid: uuid} = Bookings.booking_from_token(token)
      assert uuid == booking.uuid

      assert Bookings.booking_from_token("garbage") == nil
      assert Bookings.booking_from_token(nil) == nil
    end
  end

  describe "queries" do
    test "list_bookings filters by service, status, and upcoming" do
      slot = slot_service_fixture()
      hotel = hotel_service_fixture()

      {:ok, timed} =
        Bookings.create_booking(slot, {tomorrow_at(10), tomorrow_at(11)}, customer_attrs())

      {:ok, dated} =
        Bookings.create_booking(hotel, {:dates, future_date(7), future_date(9)}, customer_attrs())

      all = Bookings.list_bookings()
      assert Enum.map(all, & &1.uuid) |> Enum.sort() == Enum.sort([timed.uuid, dated.uuid])

      assert [%{uuid: uuid}] = Bookings.list_bookings(service_uuid: slot.uuid)
      assert uuid == timed.uuid

      # Upcoming includes both (both are in the future).
      assert length(Bookings.list_bookings(upcoming: true)) == 2

      {:ok, _} = Bookings.cancel_booking(timed)
      assert [%{uuid: cancelled_uuid}] = Bookings.list_bookings(status: "cancelled")
      assert cancelled_uuid == timed.uuid
    end
  end

  # login_required checks only that a user uuid is present; FK integrity
  # needs a real user row.
  defp create_user_uuid(_uuid) do
    {:ok, %{rows: [[uuid]]}} =
      SQL.query(
        PhoenixKitBookings.Test.Repo,
        "INSERT INTO phoenix_kit_users (email, hashed_password, inserted_at, updated_at) " <>
          "VALUES ($1, 'x', NOW(), NOW()) RETURNING uuid",
        ["booker-#{System.unique_integer([:positive])}@example.com"]
      )

    Ecto.UUID.load!(uuid)
  end
end
