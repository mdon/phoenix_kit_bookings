defmodule PhoenixKitBookings.Web.PublicLiveTest do
  use PhoenixKitBookings.LiveCase, async: true

  alias PhoenixKitBookings.Bookings

  describe "public services index" do
    test "lists only active services", %{conn: conn} do
      active = slot_service_fixture()
      inactive = slot_service_fixture()
      {:ok, _} = PhoenixKitBookings.Services.set_status(inactive, "inactive")

      {:ok, _view, html} = live(conn, "/bookings")

      assert html =~ active.name
      refute html =~ inactive.name
    end
  end

  describe "book page — fixed slots" do
    test "full happy path: pick a slot, submit details, get a manage link", %{conn: conn} do
      service = slot_service_fixture()

      {:ok, view, html} = live(conn, "/book/#{service.slug}")
      assert html =~ service.name

      # Move the picker to tomorrow (today's early slots may be in the past).
      tomorrow = Date.add(Date.utc_today(), 1)

      view
      |> form("form[phx-change=pick_date]")
      |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      html =
        view
        |> element(~s{button[phx-click="pick_slot"][phx-value-start="10:00:00"]})
        |> render_click()

      assert html =~ "Your name"

      html =
        view
        |> form("form[phx-submit=submit_details]", %{
          "booking" => %{
            "customer_name" => "Walk In",
            "customer_email" => "walkin@example.com"
          }
        })
        |> render_submit()

      assert html =~ "Booked!"
      assert html =~ "/bookings/manage/"

      assert [booking] = Bookings.list_bookings(service_uuid: service.uuid)
      assert booking.customer_email == "walkin@example.com"
      assert booking.status == "confirmed"
    end

    test "a taken slot is not offered", %{conn: conn} do
      service = slot_service_fixture()
      tomorrow = Date.add(Date.utc_today(), 1)
      starts_at = DateTime.new!(tomorrow, ~T[10:00:00], "Etc/UTC")

      {:ok, _} =
        Bookings.create_booking(
          service,
          {starts_at, DateTime.add(starts_at, 3600, :second)},
          customer_attrs()
        )

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      html =
        view
        |> form("form[phx-change=pick_date]")
        |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      refute html =~ ~s{phx-value-start="10:00:00"}
      assert html =~ ~s{phx-value-start="11:00:00"}
    end

    test "login_required service blocks anonymous visitors at selection", %{conn: conn} do
      service = slot_service_fixture(%{"signup_policy" => "login_required"})
      tomorrow = Date.add(Date.utc_today(), 1)

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      view
      |> form("form[phx-change=pick_date]")
      |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      html =
        view
        |> element(~s{button[phx-click="pick_slot"][phx-value-start="10:00:00"]})
        |> render_click()

      assert html =~ "Please log in"
    end

    test "unknown slug renders the not-found panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/book/no-such-service")
      assert html =~ "does not exist"
    end
  end

  describe "book page — nightly stays" do
    test "books a stay through the date picker", %{conn: conn} do
      service = hotel_service_fixture()
      starts_on = Date.add(Date.utc_today(), 7)
      ends_on = Date.add(starts_on, 2)

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      html =
        view
        |> form("form[phx-submit=pick_dates]", %{
          "picker" => %{
            "starts_on" => Date.to_iso8601(starts_on),
            "ends_on" => Date.to_iso8601(ends_on)
          }
        })
        |> render_submit()

      assert html =~ "2 night(s)"

      view
      |> form("form[phx-submit=submit_details]", %{
        "booking" => %{
          "customer_name" => "Hotel Guest",
          "customer_email" => "guest@example.com"
        }
      })
      |> render_submit()

      assert [booking] = Bookings.list_bookings(service_uuid: service.uuid)
      assert booking.starts_on == starts_on
      assert booking.ends_on == ends_on
    end
  end

  describe "book page — free-form" do
    test "books an arbitrary range", %{conn: conn} do
      service = freeform_service_fixture()
      tomorrow = Date.add(Date.utc_today(), 1)

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      html =
        view
        |> form("form[phx-submit=pick_free]", %{
          "picker" => %{
            "date" => Date.to_iso8601(tomorrow),
            "start_time" => "06:00",
            "end_time" => "14:00"
          }
        })
        |> render_submit()

      assert html =~ "Your name"

      view
      |> form("form[phx-submit=submit_details]", %{
        "booking" => %{
          "customer_name" => "Lifter",
          "customer_email" => "lifter@example.com"
        }
      })
      |> render_submit()

      assert [booking] = Bookings.list_bookings(service_uuid: service.uuid)
      assert DateTime.diff(booking.ends_at, booking.starts_at, :hour) == 8
    end

    test "refuses a span the site's zone would not store as picked", %{conn: conn} do
      # A free-form service has no slot grid, so the grid's daylight-saving
      # guard never sees this pick: 02:30–03:30 on a spring-forward Sunday
      # would be stored as thirty minutes (03:00–03:59 never happens), or
      # ninety on the fall-back one.
      {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", "Europe/Tallinn")
      service = freeform_service_fixture()
      gap_date = next_spring_forward()

      {:ok, view, _html} = live(conn, "/book/#{service.slug}")

      html =
        view
        |> form("form[phx-submit=pick_free]", %{
          "picker" => %{
            "date" => Date.to_iso8601(gap_date),
            "start_time" => "02:30",
            "end_time" => "03:30"
          }
        })
        |> render_submit()

      refute html =~ "Your name"
      assert Bookings.list_bookings(service_uuid: service.uuid) == []

      # The same service takes an ordinary span on the very same day.
      html =
        view
        |> form("form[phx-submit=pick_free]", %{
          "picker" => %{
            "date" => Date.to_iso8601(gap_date),
            "start_time" => "10:00",
            "end_time" => "11:00"
          }
        })
        |> render_submit()

      assert html =~ "Your name"
    end
  end

  describe "manage page" do
    test "shows the booking and cancels it", %{conn: conn} do
      service = slot_service_fixture()
      tomorrow = Date.add(Date.utc_today(), 1)
      starts_at = DateTime.new!(tomorrow, ~T[10:00:00], "Etc/UTC")

      {:ok, booking} =
        Bookings.create_booking(
          service,
          {starts_at, DateTime.add(starts_at, 3600, :second)},
          customer_attrs()
        )

      token = Bookings.manage_token(booking)

      {:ok, view, html} = live(conn, "/bookings/manage/#{token}")
      assert html =~ booking.customer_name

      html = view |> element(~s{button[phx-click="cancel"]}) |> render_click()
      assert html =~ "cancelled"
      assert Bookings.get_booking(booking.uuid).status == "cancelled"
    end

    test "garbage tokens get the invalid-link panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/bookings/manage/garbage")
      assert html =~ "invalid or has expired"
    end
  end

  describe "embeddable widget" do
    test "mounts via live_isolated and books end to end", %{conn: conn} do
      service = slot_service_fixture()
      tomorrow = Date.add(Date.utc_today(), 1)

      {:ok, view, html} =
        live_isolated(conn, PhoenixKitBookings.Web.Public.BookingWidgetLive,
          session: %{"slug" => service.slug}
        )

      assert html =~ service.name

      view
      |> form("form[phx-change=pick_date]")
      |> render_change(%{"picker" => %{"date" => Date.to_iso8601(tomorrow)}})

      view
      |> element(~s{button[phx-click="pick_slot"][phx-value-start="10:00:00"]})
      |> render_click()

      html =
        view
        |> form("form[phx-submit=submit_details]", %{
          "booking" => %{
            "customer_name" => "Embedded Guest",
            "customer_email" => "embed@example.com"
          }
        })
        |> render_submit()

      assert html =~ "Booked!"
      assert [_booking] = Bookings.list_bookings(service_uuid: service.uuid)
    end

    test "widget with an unknown slug shows the unavailable panel", %{conn: conn} do
      {:ok, _view, html} =
        live_isolated(conn, PhoenixKitBookings.Web.Public.BookingWidgetLive,
          session: %{"slug" => "nope"}
        )

      assert html =~ "not currently taking bookings"
    end
  end

  # The next date whose 02:30–03:30 the site's zone cannot store as an hour —
  # computed rather than hard-coded so the test keeps meaning after the date
  # passes.
  defp next_spring_forward do
    today = Date.utc_today()
    offset = Enum.find(1..400, &(not intact?(Date.add(today, &1))))
    Date.add(today, offset)
  end

  defp intact?(date) do
    PhoenixKitBookings.Engine.frame_span_intact?(
      date,
      ~T[02:30:00],
      date,
      ~T[03:30:00],
      "Europe/Tallinn"
    )
  end
end
