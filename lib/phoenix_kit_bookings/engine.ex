defmodule PhoenixKitBookings.Engine do
  @moduledoc """
  Adapter between the Bookings domain and `phoenix_live_calendar`'s booking
  rules engine (Layer 3: `BookingConfig` / `Availability` / `Constraints` /
  `TimeSlots`), plus the day/night path (`DayEngine`) the lib doesn't cover.

  ## Time frame

  All minute-unit math runs in the **site frame** — wall-clock time in the
  site's configured zone (core's `"time_zone"` setting: an IANA id, or a
  legacy fixed offset on a site that never touched the picker). v1
  services are physical (hotel / massage parlor / gym), so
  slots are shown and validated in venue-local time regardless of the
  viewer (the Cal.com `lockTimeZoneToggleOnBookingPage` behavior). Storage
  is always true UTC: `frame_to_utc/1` on the way in, `utc_to_frame/1` on
  the way out. Frame datetimes are UTC-tagged wall clocks; each conversion
  resolves the zone at the instant converted, so a named zone follows
  daylight saving on the date of the booking, not on the day it was made.

  Day/night services never touch clock time — dates are frame-free by the
  workspace's all-day convention.

  ## Unbounded duration

  `BookingConfig.effective_max_duration/1` treats `nil` as "same as
  `duration`", so a free-form service with no ceiling (`max_duration:
  nil`) maps to a large sentinel instead; real fit is still enforced by
  the availability-window check. (Candidate upstream tweak: an explicit
  unbounded semantic in the lib.)
  """

  alias PhoenixKitBookings.Engine.DayEngine
  alias PhoenixKitBookings.Schemas.{AvailabilityRule, Booking, Service}
  alias PhoenixLiveCalendar.{Availability, BookingConfig, Event}
  alias PhoenixLiveCalendar.Utils.{Constraints, TimeSlots}

  # 366 days in minutes — "no ceiling" sentinel for free-form services.
  @unbounded_minutes 527_040

  # ── Config mapping ───────────────────────────────────────────────────

  @doc "Maps a Service row onto the lib's `%BookingConfig{}` (minute units)."
  def booking_config(%Service{} = service) do
    {min_dur, max_dur} =
      if service.flexible_duration do
        {service.min_duration || service.duration, service.max_duration || @unbounded_minutes}
      else
        {nil, nil}
      end

    %BookingConfig{
      duration: service.duration,
      min_duration: min_dur,
      max_duration: max_dur,
      slot_interval: service.slot_interval,
      buffer_before: service.buffer_before,
      buffer_after: service.buffer_after,
      min_notice: service.min_notice,
      max_advance: service.max_advance,
      seats: service.seats,
      availability: [],
      timezone: nil
    }
  end

  @doc """
  Maps availability rules onto lib `%Availability{}` structs. A service
  with no rules is always open — a synthetic full-day window keeps slot
  generation and validation consistent.
  """
  def lib_availability([]), do: [full_day_window()]

  def lib_availability(rules) when is_list(rules) do
    Enum.map(rules, fn %AvailabilityRule{} = rule ->
      %Availability{
        days_of_week: rule.days_of_week,
        date: rule.date,
        start_time: rule.start_time || ~T[00:00:00],
        end_time: rule.end_time || ~T[23:59:59],
        available: rule.available,
        resource_id: nil
      }
    end)
  end

  defp full_day_window do
    %Availability{
      days_of_week: [1, 2, 3, 4, 5, 6, 7],
      start_time: ~T[00:00:00],
      end_time: ~T[23:59:59],
      available: true
    }
  end

  # ── Validation ───────────────────────────────────────────────────────

  @doc """
  Validates a booking request against the service's rules and the current
  active bookings. Advisory — `PhoenixKitBookings.Bookings.create_booking/5`
  re-runs it inside a locked transaction.

  `range` is `{starts_at_utc, ends_at_utc}` (DateTime, minute services) or
  `{:dates, starts_on, ends_on}` (day/night services).

  Returns `:ok | {:error, reason_atom, message}`.
  """
  def validate_request(service, rules, range, active_bookings, opts \\ [])

  def validate_request(
        %Service{time_unit: "minutes"} = service,
        rules,
        {%DateTime{} = starts_at, %DateTime{} = ends_at},
        active_bookings,
        opts
      ) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    extra_events = Keyword.get(opts, :extra_events, [])

    Constraints.validate_booking(
      utc_to_frame(starts_at),
      utc_to_frame(ends_at),
      booking_config(service),
      bookings_to_events(active_bookings, service) ++ extra_events,
      now: utc_to_frame(now),
      availabilities: lib_availability(rules)
    )
  end

  def validate_request(
        %Service{time_unit: unit} = service,
        rules,
        {:dates, %Date{} = starts_on, %Date{} = ends_on},
        active_bookings,
        opts
      )
      when unit in ["day", "night"] do
    DayEngine.validate(service, rules, starts_on, ends_on, active_bookings,
      today: Keyword.get(opts, :today, today())
    )
  end

  def validate_request(_service, _rules, _range, _bookings, _opts),
    do: {:error, :invalid_range, "Request shape does not match the service's time unit"}

  # ── Slot / day generation for pickers ────────────────────────────────

  @doc """
  Bookable slots of a minute service on a frame-local date:
  `[{start_time, end_time, :available | :booked | :unavailable}]`.

  A wall clock the site's zone skips that day — 03:00–03:59 on the
  spring-forward Sunday in a European zone — is `:unavailable`: the lib
  builds the grid from minutes and does not know the day is 23 hours long,
  and such a slot would otherwise resolve to the instant after the jump,
  landing on top of the next slot (a 03:30–04:30 pick stored as 04:00–04:30).
  `tz` defaults to the site's setting; tests pass a zone explicitly.
  """
  def bookable_slots(service, rules, date, bookings, tz \\ site_tz())

  def bookable_slots(
        %Service{time_unit: "minutes"} = service,
        rules,
        %Date{} = date,
        bookings,
        tz
      ) do
    date
    |> TimeSlots.bookable_slots(
      %{booking_config(service) | availability: nil},
      lib_availability(rules),
      bookings_to_events(bookings, service)
    )
    |> Enum.map(fn {start_time, end_time, status} ->
      if wall_clock_exists?(date, start_time, tz),
        do: {start_time, end_time, status},
        else: {start_time, end_time, :unavailable}
    end)
  end

  # A wall clock exists in the zone when reading it and showing it again
  # gives the same clock; one inside a spring-forward gap comes back an hour
  # later.
  defp wall_clock_exists?(date, time, tz) do
    utc = from_frame(date, time, tz)
    back = to_frame(utc, tz)
    DateTime.to_date(back) == date and Time.compare(DateTime.to_time(back), time) == :eq
  end

  @doc """
  Per-date remaining capacity of a day/night service over a date range:
  `%{date => remaining_seats}`. Closed dates map to `0`.
  """
  def day_capacity(%Service{} = service, rules, %Date{} = from, %Date{} = until, bookings) do
    DayEngine.capacity_by_date(service, rules, from, until, bookings)
  end

  # ── Event mapping ────────────────────────────────────────────────────

  @doc """
  Maps active bookings onto lib `%Event{}`s in the site frame.

  `overlap: seats > 1` is deliberate: with one seat the event must BLOCK
  (`Constraints.validate_no_overlap` rejects only `overlap: false`
  events); with pooled seats events must pass the overlap check and be
  COUNTED by `validate_capacity`/`slot_status` instead.

  Each event is pre-expanded by the service buffers
  (`[start - buffer_before, end + buffer_after)`) because the lib buffers
  only the REQUEST side: with both sides expanded, two consecutive
  bookings need a gap of `buffer_after + buffer_before` — the existing
  booking's cleanup plus the new booking's prep — which is the intended
  semantics for a shared per-service buffer config.
  """
  def bookings_to_events(bookings, %Service{} = service) do
    pooled = service.seats > 1
    before_s = service.buffer_before * 60
    after_s = service.buffer_after * 60

    bookings
    |> Enum.filter(&(Booking.active?(&1) and not is_nil(&1.starts_at)))
    |> Enum.map(fn booking ->
      %Event{
        id: booking.uuid,
        title: "",
        start: booking.starts_at |> utc_to_frame() |> DateTime.add(-before_s, :second),
        end: booking.ends_at |> utc_to_frame() |> DateTime.add(after_s, :second),
        overlap: pooled,
        status: :confirmed
      }
    end)
  end

  @doc """
  Maps timed bookings onto ABSOLUTELY blocking events (`overlap: false`,
  no buffer expansion) — provider cross-service conflicts: a person can't
  be in two places regardless of the current service's seat pool.
  """
  def blocking_events(bookings) do
    bookings
    |> Enum.filter(&(Booking.active?(&1) and not is_nil(&1.starts_at)))
    |> Enum.map(fn booking ->
      %Event{
        id: booking.uuid,
        title: "",
        start: utc_to_frame(booking.starts_at),
        end: utc_to_frame(booking.ends_at),
        overlap: false,
        status: :confirmed
      }
    end)
  end

  # ── Site time frame ──────────────────────────────────────────────────
  #
  # The frame is the site's wall clock tagged UTC, so the lib's minute
  # arithmetic never sees a zone. Both conversions resolve the site's zone
  # AT THE INSTANT BEING CONVERTED through core's helpers (`shift_to_offset/2`
  # in, `parse_datetime_local/2` out — both older than the 2.0 pin, both
  # per-instant on any core that knows IANA ids).
  #
  # They used to add one scalar, `offset_to_seconds/1` of the setting. Since
  # core 2.13.9 that setting holds an IANA id on any site that touched the
  # picker, and the scalar was first 0 (every slot rendered and stored as
  # UTC — three hours off in Tallinn) and, from 2.14.1, TODAY's offset — so a
  # booking made in September for a November 10:00 slot was stored an hour
  # early, and every existing booking from the other daylight-saving season
  # displayed an hour off.

  @doc """
  The site's timezone value — an IANA id such as `Europe/Tallinn`, or a
  legacy fixed offset such as `"2"` on a site that never touched the
  picker. `"0"` when settings are unreachable (`Settings.get_setting/2`
  already answers the default then).
  """
  @spec site_tz() :: String.t()
  def site_tz, do: PhoenixKit.Settings.get_setting("time_zone", "0")

  @doc "Shifts a true-UTC datetime into the site frame (UTC-tagged wall clock)."
  @spec utc_to_frame(DateTime.t()) :: DateTime.t()
  def utc_to_frame(%DateTime{} = dt), do: to_frame(dt, site_tz())

  @doc "Reads a site-frame wall clock back as the true UTC instant."
  @spec frame_to_utc(DateTime.t()) :: DateTime.t()
  def frame_to_utc(%DateTime{} = dt), do: from_frame(dt, site_tz())

  @doc "Builds a true-UTC datetime from a frame-local date + time."
  @spec frame_to_utc(Date.t(), Time.t()) :: DateTime.t()
  def frame_to_utc(%Date{} = date, %Time{} = time), do: from_frame(date, time, site_tz())

  @doc """
  `utc_to_frame/1` for an explicit zone value (an IANA id or a legacy
  offset) — the site setting is read by the one-argument form.
  """
  @spec to_frame(DateTime.t(), String.t()) :: DateTime.t()
  def to_frame(%DateTime{} = dt, tz) do
    dt
    |> PhoenixKit.Utils.Date.shift_to_offset(tz)
    |> DateTime.to_naive()
    |> DateTime.from_naive!("Etc/UTC")
  end

  @doc """
  `frame_to_utc/1,2` for an explicit zone value.

  A wall clock that does not exist (spring-forward gap) resolves to the
  instant the clocks jump to; one that happens twice (fall-back overlap)
  resolves to the first occurrence — core's `parse_datetime_local/2` rules.
  """
  @spec from_frame(DateTime.t(), String.t()) :: DateTime.t()
  def from_frame(%DateTime{} = dt, tz) do
    from_frame(DateTime.to_date(dt), DateTime.to_time(dt), tz)
  end

  @doc "`from_frame/2` for a frame-local date + time."
  @spec from_frame(Date.t(), Time.t(), String.t()) :: DateTime.t()
  def from_frame(%Date{} = date, %Time{} = time, tz) do
    wall = "#{Date.to_iso8601(date)}T#{Calendar.strftime(time, "%H:%M:%S")}"
    {micro, precision} = time.microsecond

    case PhoenixKit.Utils.Date.parse_datetime_local(wall, tz) do
      # The wall-clock string carries whole seconds; put the microseconds back
      # so a frame round-trips exactly.
      {:ok, utc} -> %{DateTime.add(utc, micro, :microsecond) | microsecond: {micro, precision}}
      # An unresolvable zone value degrades to UTC — the same default the
      # scalar path answered with 0.
      _ -> DateTime.new!(date, time, "Etc/UTC")
    end
  end

  @doc "Today's date in the site frame."
  @spec today() :: Date.t()
  def today, do: DateTime.utc_now() |> utc_to_frame() |> DateTime.to_date()
end
