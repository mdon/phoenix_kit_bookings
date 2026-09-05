defmodule PhoenixKitBookings.EngineTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBookings.Engine
  alias PhoenixKitBookings.Engine.DayEngine
  alias PhoenixKitBookings.Schemas.{AvailabilityRule, Booking, Service}
  alias PhoenixLiveCalendar.{Availability, BookingConfig}

  # Pure unit tests — no DB. The site offset resolves to "0" (Settings
  # unavailable rescues to the default), so frame == UTC here.

  defp minutes_service(attrs \\ []) do
    struct!(
      %Service{
        uuid: Ecto.UUID.generate(),
        name: "Massage",
        time_unit: "minutes",
        duration: 60,
        slot_interval: 60,
        buffer_before: 0,
        buffer_after: 0,
        min_notice: 0,
        seats: 1,
        flexible_duration: false,
        status: "active",
        signup_policy: "anyone",
        require_approval: false
      },
      attrs
    )
  end

  defp night_service(attrs \\ []) do
    struct!(
      %Service{
        uuid: Ecto.UUID.generate(),
        name: "Double room",
        time_unit: "night",
        duration: 60,
        seats: 3,
        buffer_before: 0,
        buffer_after: 0,
        min_notice: 0,
        status: "active",
        signup_policy: "anyone",
        require_approval: false
      },
      attrs
    )
  end

  defp rule(attrs) do
    struct!(%AvailabilityRule{available: true}, attrs)
  end

  defp booking_on(starts_on, ends_on, status \\ "confirmed") do
    %Booking{
      uuid: Ecto.UUID.generate(),
      starts_on: starts_on,
      ends_on: ends_on,
      status: status
    }
  end

  describe "site frame across daylight saving" do
    # Europe/Tallinn is UTC+2 in November and UTC+3 in July. Each conversion
    # must resolve the zone ON THE DATE CONVERTED — the previous code applied
    # today's offset to every date, so whichever season the suite runs in,
    # one of these two months came out an hour off.
    test "to_frame/2 shows the wall clock of the instant's own season" do
      assert Engine.to_frame(~U[2026-11-05 08:00:00Z], "Europe/Tallinn") ==
               ~U[2026-11-05 10:00:00Z]

      assert Engine.to_frame(~U[2026-07-05 07:00:00Z], "Europe/Tallinn") ==
               ~U[2026-07-05 10:00:00Z]
    end

    test "from_frame/3 stores the instant of the slot's own season" do
      assert Engine.from_frame(~D[2026-11-05], ~T[10:00:00], "Europe/Tallinn") ==
               ~U[2026-11-05 08:00:00Z]

      assert Engine.from_frame(~D[2026-07-05], ~T[10:00:00], "Europe/Tallinn") ==
               ~U[2026-07-05 07:00:00Z]
    end

    test "a legacy fixed offset never moves" do
      assert Engine.from_frame(~D[2026-11-05], ~T[10:00:00], "2") == ~U[2026-11-05 08:00:00Z]
      assert Engine.from_frame(~D[2026-07-05], ~T[10:00:00], "2") == ~U[2026-07-05 08:00:00Z]
      assert Engine.to_frame(~U[2026-07-05 08:00:00Z], "2") == ~U[2026-07-05 10:00:00Z]
    end

    test "the frame round-trips in both seasons" do
      for utc <- [~U[2026-01-15 21:30:00Z], ~U[2026-07-15 21:30:00Z]],
          tz <- ["Europe/Tallinn", "America/New_York", "5.5", "0"] do
        assert utc |> Engine.to_frame(tz) |> Engine.from_frame(tz) == utc, "#{tz} #{utc}"
      end
    end

    test "a skipped wall clock jumps forward, a repeated one takes the first occurrence" do
      # Tallinn springs forward 2026-03-29 03:00 → 04:00 and falls back
      # 2026-10-25 04:00 → 03:00.
      assert Engine.from_frame(~D[2026-03-29], ~T[03:30:00], "Europe/Tallinn") ==
               ~U[2026-03-29 01:00:00Z]

      assert Engine.from_frame(~D[2026-10-25], ~T[03:30:00], "Europe/Tallinn") ==
               ~U[2026-10-25 00:30:00Z]
    end

    test "microseconds survive the round trip" do
      utc = ~U[2026-07-15 08:00:00.123456Z]

      assert utc |> Engine.to_frame("Europe/Tallinn") |> Engine.from_frame("Europe/Tallinn") ==
               utc

      assert Engine.from_frame(~D[2026-07-15], ~T[10:00:00.5], "2") == ~U[2026-07-15 08:00:00.5Z]
    end

    test "slots inside a spring-forward gap are unavailable" do
      # Tallinn skips 03:00–03:59 on 2026-03-29.
      service = minutes_service(duration: 30, slot_interval: 30)
      slots = Engine.bookable_slots(service, [], ~D[2026-03-29], [], "Europe/Tallinn")
      by_start = Map.new(slots, fn {start_t, _end_t, status} -> {start_t, status} end)

      assert by_start[~T[02:30:00]] == :available
      assert by_start[~T[03:00:00]] == :unavailable
      assert by_start[~T[03:30:00]] == :unavailable
      assert by_start[~T[04:00:00]] == :available

      # The same grid on an ordinary day, or in a zone that never moves, is untouched.
      assert Engine.bookable_slots(service, [], ~D[2026-03-28], [], "Europe/Tallinn")
             |> Enum.all?(fn {_s, _e, status} -> status == :available end)

      assert Engine.bookable_slots(service, [], ~D[2026-03-29], [], "2")
             |> Enum.all?(fn {_s, _e, status} -> status == :available end)
    end

    test "an unresolvable zone value degrades to UTC" do
      assert Engine.from_frame(~D[2026-07-05], ~T[10:00:00], "nonsense") ==
               ~U[2026-07-05 10:00:00Z]

      assert Engine.to_frame(~U[2026-07-05 10:00:00Z], "nonsense") == ~U[2026-07-05 10:00:00Z]
    end
  end

  describe "booking_config/1" do
    test "fixed-slot service maps duration and interval, no free-form bounds" do
      config = Engine.booking_config(minutes_service())

      assert %BookingConfig{duration: 60, slot_interval: 60, seats: 1} = config
      assert BookingConfig.effective_min_duration(config) == 60
      assert BookingConfig.effective_max_duration(config) == 60
    end

    test "flexible service with nil max_duration maps to the unbounded sentinel" do
      config =
        Engine.booking_config(
          minutes_service(flexible_duration: true, min_duration: 30, max_duration: nil)
        )

      assert BookingConfig.effective_min_duration(config) == 30
      # An 8-hour gym session must not trip :too_long.
      assert BookingConfig.effective_max_duration(config) > 8 * 60
    end

    test "flexible service with explicit max keeps it" do
      config =
        Engine.booking_config(
          minutes_service(flexible_duration: true, min_duration: 30, max_duration: 120)
        )

      assert BookingConfig.effective_max_duration(config) == 120
    end
  end

  describe "lib_availability/1" do
    test "no rules synthesizes an always-open week" do
      assert [%Availability{days_of_week: [1, 2, 3, 4, 5, 6, 7], available: true}] =
               Engine.lib_availability([])
    end

    test "maps rule rows onto lib structs" do
      rules = [
        rule(days_of_week: [1, 2], start_time: ~T[09:00:00], end_time: ~T[17:00:00]),
        rule(date: ~D[2030-01-01], available: false)
      ]

      assert [
               %Availability{days_of_week: [1, 2], start_time: ~T[09:00:00]},
               %Availability{date: ~D[2030-01-01], available: false}
             ] = Engine.lib_availability(rules)
    end
  end

  describe "validate_request/5 — minute services" do
    test "free-form multi-hour booking passes with no ceiling" do
      service = minutes_service(flexible_duration: true, min_duration: 30, max_duration: nil)
      starts_at = DateTime.add(DateTime.utc_now(), 24 * 3600, :second)
      ends_at = DateTime.add(starts_at, 5 * 3600, :second)

      assert :ok = Engine.validate_request(service, [], {starts_at, ends_at}, [])
    end

    test "rejects a range shape that doesn't match the unit" do
      service = minutes_service()

      assert {:error, :invalid_range, _} =
               Engine.validate_request(service, [], {:dates, ~D[2030-01-01], ~D[2030-01-02]}, [])
    end
  end

  describe "DayEngine.validate/6" do
    @today ~D[2030-06-10]

    test "accepts a valid stay" do
      assert :ok =
               DayEngine.validate(night_service(), [], ~D[2030-06-15], ~D[2030-06-17], [],
                 today: @today
               )
    end

    test "rejects inverted and same-day ranges" do
      assert {:error, :invalid_range, _} =
               DayEngine.validate(night_service(), [], ~D[2030-06-15], ~D[2030-06-15], [],
                 today: @today
               )
    end

    test "rejects past arrivals" do
      assert {:error, :in_past, _} =
               DayEngine.validate(night_service(), [], ~D[2030-06-09], ~D[2030-06-11], [],
                 today: @today
               )
    end

    test "enforces min_stay and max_stay" do
      service = night_service(min_stay: 2, max_stay: 4)

      assert {:error, :too_short, _} =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2030-06-16], [], today: @today)

      assert {:error, :too_long, _} =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2030-06-20], [], today: @today)

      assert :ok =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2030-06-18], [], today: @today)
    end

    test "enforces max_advance and day-granular min_notice" do
      service = night_service(max_advance: 10, min_notice: 2 * 1440)

      assert {:error, :too_far_ahead, _} =
               DayEngine.validate(service, [], ~D[2030-06-25], ~D[2030-06-26], [], today: @today)

      assert {:error, :insufficient_notice, _} =
               DayEngine.validate(service, [], ~D[2030-06-11], ~D[2030-06-12], [], today: @today)
    end

    test "a blackout date override blocks stays covering it" do
      rules = [rule(date: ~D[2030-06-16], available: false)]

      assert {:error, :outside_availability, _} =
               DayEngine.validate(night_service(), rules, ~D[2030-06-15], ~D[2030-06-17], [],
                 today: @today
               )

      # A stay ending on the blackout date (exclusive end) is fine.
      assert :ok =
               DayEngine.validate(night_service(), rules, ~D[2030-06-15], ~D[2030-06-16], [],
                 today: @today
               )
    end

    test "pooled capacity: the seat taken by overlapping stays" do
      service = night_service(seats: 2)

      active = [
        booking_on(~D[2030-06-15], ~D[2030-06-18]),
        booking_on(~D[2030-06-16], ~D[2030-06-17])
      ]

      # 2030-06-16 has both stays -> full.
      assert {:error, :at_capacity, _} =
               DayEngine.validate(service, [], ~D[2030-06-16], ~D[2030-06-17], active,
                 today: @today
               )

      # 2030-06-17 only overlaps the first stay -> one seat free.
      assert :ok =
               DayEngine.validate(service, [], ~D[2030-06-17], ~D[2030-06-18], active,
                 today: @today
               )
    end

    test "cancelled bookings free their seats" do
      service = night_service(seats: 1)
      active = [booking_on(~D[2030-06-15], ~D[2030-06-17], "cancelled")]

      assert :ok =
               DayEngine.validate(service, [], ~D[2030-06-15], ~D[2030-06-17], active,
                 today: @today
               )
    end
  end

  describe "DayEngine.open_date?/2 weekly semantics" do
    test "with only weekly OPEN rules, unlisted weekdays are closed" do
      rules = [rule(days_of_week: [1, 2, 3, 4, 5])]

      assert DayEngine.open_date?(rules, ~D[2030-06-10])
      refute DayEngine.open_date?(rules, ~D[2030-06-15])
    end

    test "with only block-outs, unlisted days stay open" do
      rules = [rule(days_of_week: [7], available: false)]

      assert DayEngine.open_date?(rules, ~D[2030-06-10])
      refute DayEngine.open_date?(rules, ~D[2030-06-16])
    end

    test "a date override wins over weekly rules" do
      rules = [
        rule(days_of_week: [1, 2, 3, 4, 5]),
        rule(date: ~D[2030-06-15], available: true)
      ]

      # Saturday, normally closed — opened by the override.
      assert DayEngine.open_date?(rules, ~D[2030-06-15])
    end
  end

  describe "DayEngine.capacity_by_date/5" do
    test "maps remaining seats per date with closures at zero" do
      service = night_service(seats: 2)
      rules = [rule(date: ~D[2030-06-12], available: false)]
      active = [booking_on(~D[2030-06-10], ~D[2030-06-12])]

      capacity =
        DayEngine.capacity_by_date(service, rules, ~D[2030-06-10], ~D[2030-06-13], active)

      assert capacity[~D[2030-06-10]] == 1
      assert capacity[~D[2030-06-11]] == 1
      assert capacity[~D[2030-06-12]] == 0
      assert capacity[~D[2030-06-13]] == 2
    end
  end

  describe "bookings_to_events/2" do
    test "seat-1 services produce blocking events, pooled produce countable" do
      timed = %Booking{
        uuid: Ecto.UUID.generate(),
        status: "confirmed",
        starts_at: ~U[2030-06-10 10:00:00Z],
        ends_at: ~U[2030-06-10 11:00:00Z]
      }

      assert [%PhoenixLiveCalendar.Event{overlap: false}] =
               Engine.bookings_to_events([timed], minutes_service(seats: 1))

      assert [%PhoenixLiveCalendar.Event{overlap: true}] =
               Engine.bookings_to_events([timed], minutes_service(seats: 5))
    end

    test "cancelled and dated bookings are dropped" do
      cancelled = %Booking{
        uuid: Ecto.UUID.generate(),
        status: "cancelled",
        starts_at: ~U[2030-06-10 10:00:00Z],
        ends_at: ~U[2030-06-10 11:00:00Z]
      }

      dated = booking_on(~D[2030-06-10], ~D[2030-06-12])

      assert [] = Engine.bookings_to_events([cancelled, dated], minutes_service())
    end
  end
end
