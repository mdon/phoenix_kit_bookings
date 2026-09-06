defmodule PhoenixKitBookings.Web.Public.BookingFlow do
  @moduledoc """
  The shared public booking flow: state, events, and markup used by BOTH
  `Public.BookLive` (the routed page) and `Public.BookingWidgetLive` (the
  `live_render/3` embeddable). The two LiveViews stay thin shells that
  delegate `handle_event/3` + `handle_info/2` here — one flow, two mounts,
  because an embeddable LiveView must not export `handle_params/3`
  (Phoenix refuses to mount it outside a router live route).

  ## Steps

  `:pick` (mode-aware slot/date/range picker) → `:details` (customer form
  or login gate) → `:done` (confirmation + manage link). The picker panel
  varies by the service's shape:

  - fixed slots — date input + slot button grid (`Engine.bookable_slots`)
  - free-form — date + start/end time inputs, validated server-side
  - day/night — check-in/check-out date inputs + remaining-capacity note

  ## Live updates

  Mounting flows subscribe to the service's PubSub topic; any booking
  mutation re-runs the current picker query, so a slot taken in another
  session greys out in real time.
  """

  use Phoenix.Component

  import Phoenix.LiveView

  alias PhoenixKitBookings.{Bookings, Engine, Errors, Paths, Pricing, Services}
  alias PhoenixKitBookings.Schemas.{Booking, Service}
  alias PhoenixKitBookings.Web.Format

  # ── Mount-side setup ─────────────────────────────────────────────────

  @doc """
  Initializes flow assigns for a mounted LiveView. `user` is the viewer's
  `%{uuid, email}`-shaped struct or nil; `prefill` optionally seeds the
  customer form (embed contract).
  """
  def assign_flow(socket, %Service{} = service, user, prefill \\ %{}) do
    if connected?(socket) do
      case PhoenixKit.Config.pubsub_server() do
        nil -> :ok
        pubsub -> Phoenix.PubSub.subscribe(pubsub, Bookings.service_topic(service.uuid))
      end
    end

    # Unit-tracked services derive capacity from their active unit count;
    # the copy keeps every downstream seats read consistent.
    service = %{service | seats: Services.effective_seats(service)}

    socket
    |> assign(
      service: service,
      rules: Services.list_rules(service.uuid),
      step: :pick,
      pick_date: Engine.today(),
      selected_range: nil,
      booking: nil,
      flow_error: nil,
      flow_error_reason: nil,
      hold_uuid: nil,
      waitlist_done: false,
      current_user: user,
      customer_form: customer_form(user, prefill)
    )
    |> refresh_pick()
  end

  @doc """
  Releases the visitor's hold when their LiveView goes away — both public
  LVs call this from `terminate/2`.
  """
  def on_terminate(socket) do
    Bookings.release_hold(socket.assigns[:hold_uuid])
    :ok
  end

  defp customer_form(user, prefill) do
    seed =
      %{}
      |> maybe_put("customer_name", prefill["customer_name"] || user_name(user))
      |> maybe_put("customer_email", prefill["customer_email"] || user_email(user))

    to_form(Booking.customer_changeset(%Booking{}, seed))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp user_name(%{username: name}) when is_binary(name), do: name
  defp user_name(_), do: nil
  defp user_email(%{email: email}) when is_binary(email), do: email
  defp user_email(_), do: nil

  # ── Picker data refresh (also runs on PubSub pings) ──────────────────

  @doc "Re-queries the data behind the current picker panel."
  def refresh_pick(%{assigns: %{service: %Service{time_unit: "minutes"} = service}} = socket) do
    date = socket.assigns.pick_date
    day_start = Engine.frame_to_utc(date, ~T[00:00:00])
    day_end = Engine.frame_to_utc(Date.add(date, 1), ~T[00:00:00])
    pad = (service.buffer_before + service.buffer_after) * 60

    active =
      Bookings.list_occupancy(
        service.uuid,
        {DateTime.add(day_start, -pad, :second), DateTime.add(day_end, pad, :second)},
        exclude_hold: socket.assigns[:hold_uuid]
      )

    slots =
      if service.flexible_duration do
        []
      else
        Engine.bookable_slots(service, socket.assigns.rules, date, active)
      end

    assign(socket, slots: slots, day_capacity: %{})
  end

  def refresh_pick(%{assigns: %{service: %Service{} = service}} = socket) do
    from = Engine.today()
    until = Date.add(from, service.max_advance || 60)

    active =
      Bookings.list_occupancy(service.uuid, {:dates, from, until},
        exclude_hold: socket.assigns[:hold_uuid]
      )

    assign(socket,
      slots: [],
      day_capacity: Engine.day_capacity(service, socket.assigns.rules, from, until, active)
    )
  end

  # ── Events (LiveViews delegate their handle_event/3 here) ────────────

  def handle_event("pick_date", %{"picker" => %{"date" => date_str}}, socket) do
    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        {:noreply, socket |> assign(pick_date: date, flow_error: nil) |> refresh_pick()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("pick_slot", %{"start" => start_str, "end" => end_str}, socket) do
    date = socket.assigns.pick_date

    with {:ok, start_t} <- parse_time(start_str),
         {:ok, end_t} <- parse_time(end_str),
         end_date = end_date_of(date, start_t, end_t),
         true <- Engine.frame_span_intact?(date, start_t, end_date, end_t) do
      range =
        {Engine.frame_to_utc(date, start_t), Engine.frame_to_utc(end_date, end_t)}

      advisory_advance(socket, range)
    else
      _ -> {:noreply, assign(socket, flow_error: Errors.message(:invalid_range))}
    end
  end

  def handle_event("pick_free", %{"picker" => params}, socket) do
    with {:ok, date} <- Date.from_iso8601(params["date"] || ""),
         {:ok, start_t} <- parse_time(params["start_time"]),
         {:ok, end_t} <- parse_time(params["end_time"]),
         end_date = end_date_of(date, start_t, end_t),
         true <- Engine.frame_span_intact?(date, start_t, end_date, end_t) do
      range = {Engine.frame_to_utc(date, start_t), Engine.frame_to_utc(end_date, end_t)}

      advisory_advance(assign(socket, pick_date: date), range)
    else
      _ -> {:noreply, assign(socket, flow_error: Errors.message(:invalid_range))}
    end
  end

  def handle_event("pick_dates", %{"picker" => params}, socket) do
    with {:ok, starts_on} <- Date.from_iso8601(params["starts_on"] || ""),
         {:ok, ends_on} <- Date.from_iso8601(params["ends_on"] || "") do
      advisory_advance(socket, {:dates, starts_on, ends_on})
    else
      _ -> {:noreply, assign(socket, flow_error: Errors.message(:invalid_range))}
    end
  end

  def handle_event("back", _params, socket) do
    Bookings.release_hold(socket.assigns[:hold_uuid])

    {:noreply,
     socket
     |> assign(step: :pick, flow_error: nil, flow_error_reason: nil, hold_uuid: nil)
     |> refresh_pick()}
  end

  def handle_event("join_waitlist", %{"waitlist" => params}, socket) do
    service = socket.assigns.service

    attrs = %{
      "date" => params["date"],
      "customer_name" => params["customer_name"],
      "customer_email" => params["customer_email"]
    }

    case Bookings.join_waitlist(service, attrs) do
      {:ok, _entry} ->
        {:noreply, assign(socket, waitlist_done: true)}

      {:error, _changeset} ->
        {:noreply,
         assign(socket, flow_error: Errors.message(:invalid_waitlist), flow_error_reason: nil)}
    end
  end

  def handle_event("validate_details", %{"booking" => params}, socket) do
    changeset = Booking.customer_changeset(%Booking{}, params)
    {:noreply, assign(socket, customer_form: to_form(changeset, action: :validate))}
  end

  def handle_event("submit_details", %{"booking" => params}, socket) do
    %{service: service, selected_range: range, current_user: user} = socket.assigns

    case Bookings.create_booking(service, range, params,
           user_uuid: user && user.uuid,
           source: "public",
           hold_uuid: socket.assigns[:hold_uuid]
         ) do
      {:ok, booking} ->
        {:noreply, assign(socket, booking: booking, step: :done, flow_error: nil, hold_uuid: nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, customer_form: to_form(changeset))}

      {:error, reason, _message} ->
        # Race lost or rules changed — back to the picker with fresh data.
        Bookings.release_hold(socket.assigns[:hold_uuid])

        {:noreply,
         socket
         |> assign(
           step: :pick,
           flow_error: Errors.message(reason),
           flow_error_reason: reason,
           hold_uuid: nil
         )
         |> refresh_pick()}
    end
  end

  # A picked span ends on the next date when it crosses midnight. The zone
  # has to resolve BOTH ends as far apart as the clocks say — a span across a
  # daylight-saving jump would be stored as a different booking than the one
  # picked, and only the fixed-slot grid marks those (`Engine.bookable_slots`);
  # a free-form service has no grid, and either picker's params arrive from
  # the client.
  defp end_date_of(date, start_t, end_t) do
    if Time.compare(end_t, start_t) == :gt, do: date, else: Date.add(date, 1)
  end

  defp advisory_advance(socket, range) do
    %{service: service, rules: rules} = socket.assigns

    active =
      Bookings.list_occupancy(service.uuid, conflict_probe(service, range),
        exclude_hold: socket.assigns[:hold_uuid]
      )

    case Engine.validate_request(service, rules, range, active) do
      :ok ->
        if service.signup_policy == "login_required" and is_nil(socket.assigns.current_user) do
          {:noreply,
           assign(socket,
             flow_error: Errors.message(:login_required),
             flow_error_reason: :login_required
           )}
        else
          {:noreply,
           socket
           |> take_hold(range)
           |> assign(
             selected_range: range,
             step: :details,
             flow_error: nil,
             flow_error_reason: nil
           )}
        end

      {:error, reason, _} ->
        {:noreply,
         socket
         |> assign(flow_error: Errors.message(reason), flow_error_reason: reason)
         |> refresh_pick()}
    end
  end

  # Reserve the picked range while the visitor types (best-effort — a
  # failed hold never blocks the flow; the locked create still decides).
  defp take_hold(socket, range) do
    Bookings.release_hold(socket.assigns[:hold_uuid])

    case Bookings.create_hold(socket.assigns.service, range) do
      {:ok, hold} -> assign(socket, hold_uuid: hold.uuid)
      _ -> assign(socket, hold_uuid: nil)
    end
  end

  # Pads each side by BOTH buffers — mirrors Bookings.conflict_window/2
  # (the request and its neighbors each expand toward the other).
  defp conflict_probe(service, {%DateTime{} = from, %DateTime{} = until}) do
    pad = (service.buffer_before + service.buffer_after) * 60
    {DateTime.add(from, -pad, :second), DateTime.add(until, pad, :second)}
  end

  defp conflict_probe(_service, {:dates, from, until}), do: {:dates, from, until}

  # ── PubSub (LiveViews delegate their handle_info/2 here) ─────────────

  def handle_info({:bookings_changed, _service_uuid}, socket) do
    {:noreply, refresh_pick(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp parse_time(nil), do: :error
  defp parse_time(str) when byte_size(str) == 5, do: Time.from_iso8601(str <> ":00")
  defp parse_time(str) when is_binary(str), do: Time.from_iso8601(str)
  defp parse_time(_), do: :error

  # ── Markup ───────────────────────────────────────────────────────────

  attr(:service, Service, required: true)
  attr(:rules, :list, required: true)
  attr(:step, :atom, required: true)
  attr(:pick_date, Date, required: true)
  attr(:slots, :list, required: true)
  attr(:day_capacity, :map, required: true)
  attr(:selected_range, :any, required: true)
  attr(:customer_form, :any, required: true)
  attr(:booking, :any, required: true)
  attr(:flow_error, :any, required: true)
  attr(:flow_error_reason, :any, default: nil)
  attr(:waitlist_done, :boolean, default: false)
  attr(:current_user, :any, required: true)

  def flow(assigns) do
    ~H"""
    <div class="flex flex-col gap-4" id={"booking-flow-#{@service.uuid}"}>
      <div>
        <h3 class="text-xl font-bold">{@service.name}</h3>
        <p :if={@service.description} class="text-sm text-base-content/70 mt-1">
          {@service.description}
        </p>
        <p class="text-xs text-base-content/50 mt-1">{Format.mode_summary(@service)}</p>
        <p :if={Pricing.tag(@service)} class="text-sm font-medium mt-1">{Pricing.tag(@service)}</p>
        <p :if={@service.checkin_time} class="text-xs text-base-content/50">
          Check-in {Calendar.strftime(@service.checkin_time, "%H:%M")}
          <span :if={@service.checkout_time}>
            · check-out {Calendar.strftime(@service.checkout_time, "%H:%M")}
          </span>
        </p>
      </div>

      <div :if={@flow_error} class="alert alert-warning text-sm">{@flow_error}</div>

      <%= case @step do %>
        <% :pick -> %>
          <.picker
            service={@service}
            pick_date={@pick_date}
            slots={@slots}
            day_capacity={@day_capacity}
            current_user={@current_user}
          />
          <.waitlist_panel
            :if={show_waitlist?(assigns)}
            pick_date={@pick_date}
            customer_form={@customer_form}
            waitlist_done={@waitlist_done}
          />
        <% :details -> %>
          <.details
            service={@service}
            selected_range={@selected_range}
            customer_form={@customer_form}
            current_user={@current_user}
          />
        <% :done -> %>
          <.done service={@service} booking={@booking} />
      <% end %>
    </div>
    """
  end

  # The waitlist offer appears when the picker came up empty (no free
  # slots on the chosen date) or the last attempt failed on capacity.
  defp show_waitlist?(%{waitlist_done: true}), do: true

  defp show_waitlist?(%{flow_error_reason: reason}) when reason in [:at_capacity, :overlap],
    do: true

  defp show_waitlist?(%{
         service: %Service{time_unit: "minutes", flexible_duration: false},
         slots: slots
       }),
       do: Enum.all?(slots, fn {_s, _e, status} -> status != :available end) and slots != []

  defp show_waitlist?(_assigns), do: false

  defp waitlist_panel(assigns) do
    ~H"""
    <div class="border-t border-base-200 pt-3">
      <div :if={@waitlist_done} class="alert alert-success text-sm">
        You're on the waitlist — we'll email you the moment a spot opens up.
      </div>
      <form :if={!@waitlist_done} phx-submit="join_waitlist" class="flex flex-col gap-2">
        <p class="text-sm text-base-content/70">
          Fully booked? Join the waitlist and get an email when a spot frees up.
        </p>
        <div class="flex flex-wrap items-end gap-2">
          <label class="fieldset">
            <span class="fieldset-legend text-xs">Date</span>
            <input
              type="date"
              name="waitlist[date]"
              value={Date.to_iso8601(@pick_date)}
              class="input input-sm"
              required
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend text-xs">Name</span>
            <input
              type="text"
              name="waitlist[customer_name]"
              value={@customer_form[:customer_name].value}
              class="input input-sm"
              required
            />
          </label>
          <label class="fieldset">
            <span class="fieldset-legend text-xs">Email</span>
            <input
              type="email"
              name="waitlist[customer_email]"
              value={@customer_form[:customer_email].value}
              class="input input-sm"
              required
            />
          </label>
          <button type="submit" class="btn btn-sm">Join waitlist</button>
        </div>
      </form>
    </div>
    """
  end

  defp picker(%{service: %Service{time_unit: unit}} = assigns) when unit in ["day", "night"] do
    ~H"""
    <form phx-submit="pick_dates" class="flex flex-col gap-3">
      <div class="flex flex-wrap items-end gap-3">
        <label class="fieldset">
          <span class="fieldset-legend text-xs">{if @service.time_unit == "night", do: "Check-in", else: "First day"}</span>
          <input
            type="date"
            name="picker[starts_on]"
            min={Date.to_iso8601(Engine.today())}
            class="input"
            required
          />
        </label>
        <label class="fieldset">
          <span class="fieldset-legend text-xs">{if @service.time_unit == "night", do: "Check-out", else: "Day after the last day"}</span>
          <input type="date" name="picker[ends_on]" class="input" required />
        </label>
        <button type="submit" class="btn btn-primary">Check availability</button>
      </div>
      <p class="text-xs text-base-content/50">
        {next_open_days_note(@day_capacity)}
      </p>
    </form>
    """
  end

  defp picker(%{service: %Service{flexible_duration: true}} = assigns) do
    ~H"""
    <form phx-submit="pick_free" class="flex flex-wrap items-end gap-3">
      <label class="fieldset">
        <span class="fieldset-legend text-xs">Date</span>
        <input
          type="date"
          name="picker[date]"
          value={Date.to_iso8601(@pick_date)}
          min={Date.to_iso8601(Engine.today())}
          class="input"
          required
        />
      </label>
      <label class="fieldset">
        <span class="fieldset-legend text-xs">From</span>
        <input type="time" name="picker[start_time]" class="input" required />
      </label>
      <label class="fieldset">
        <span class="fieldset-legend text-xs">To</span>
        <input type="time" name="picker[end_time]" class="input" required />
      </label>
      <button type="submit" class="btn btn-primary">Continue</button>
    </form>
    """
  end

  defp picker(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <form phx-change="pick_date" class="w-fit">
        <label class="fieldset">
          <span class="fieldset-legend text-xs">Date</span>
          <input
            type="date"
            name="picker[date]"
            value={Date.to_iso8601(@pick_date)}
            min={Date.to_iso8601(Engine.today())}
            class="input"
          />
        </label>
      </form>

      <div :if={available_slots(@slots) == []} class="text-sm text-base-content/50 py-4">
        No free times on this date — try another day.
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
        <button
          :for={{start_t, end_t, status} <- @slots}
          :if={status == :available}
          class="btn btn-outline btn-sm"
          phx-click="pick_slot"
          phx-value-start={Time.to_iso8601(start_t)}
          phx-value-end={Time.to_iso8601(end_t)}
        >
          {Calendar.strftime(start_t, "%H:%M")}
        </button>
      </div>
    </div>
    """
  end

  defp details(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <div class="alert text-sm">
        <span>
          {selected_label(@service, @selected_range)}
          <span :if={@service.require_approval} class="badge badge-warning badge-sm ml-2">
            needs approval
          </span>
        </span>
      </div>

      <.form
        for={@customer_form}
        phx-change="validate_details"
        phx-submit="submit_details"
        class="flex flex-col gap-3"
      >
        <PhoenixKitWeb.Components.Core.Input.input
          field={@customer_form[:customer_name]}
          type="text"
          label="Your name"
        />
        <PhoenixKitWeb.Components.Core.Input.input
          field={@customer_form[:customer_email]}
          type="email"
          label="Email"
        />
        <PhoenixKitWeb.Components.Core.Input.input
          field={@customer_form[:customer_phone]}
          type="tel"
          label="Phone (optional)"
        />
        <PhoenixKitWeb.Components.Core.Textarea.textarea
          field={@customer_form[:notes]}
          label="Notes (optional)"
        />
        <p :if={Pricing.total(@service, @selected_range)} class="text-sm font-medium">
          Total: {Pricing.format(Pricing.total(@service, @selected_range), @service.currency)}
        </p>
        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary">
            {if @service.require_approval, do: "Request booking", else: "Confirm booking"}
          </button>
          <button type="button" class="btn btn-ghost" phx-click="back">Back</button>
        </div>
      </.form>
    </div>
    """
  end

  defp done(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <div class={["alert", @booking.status == "pending" && "alert-warning" || "alert-success"]}>
        <span :if={@booking.status == "confirmed"}>
          Booked! {Format.format_range(@booking)} is yours.
        </span>
        <span :if={@booking.status == "pending"}>
          Request received for {Format.format_range(@booking)}. You'll hear back once it's approved.
        </span>
      </div>
      <p :if={unit_line(@booking)} class="text-sm">{unit_line(@booking)}</p>
      <p :if={@booking.total_price} class="text-sm font-medium">
        Total: {Pricing.format(@booking.total_price, @booking.currency)}
      </p>
      <div class="text-sm">
        Manage or cancel this booking any time (a confirmation email with a
        calendar invite is on its way):
        <a
          href={Paths.public_manage(Bookings.manage_token(@booking))}
          class="link link-primary break-all"
        >
          {Paths.public_manage_url(Bookings.manage_token(@booking))}
        </a>
      </div>
    </div>
    """
  end

  defp unit_line(%Booking{unit_uuid: nil}), do: nil

  defp unit_line(%Booking{unit_uuid: unit_uuid}) do
    case Services.unit_name(unit_uuid) do
      nil -> nil
      name -> "Assigned: #{name}"
    end
  end

  defp available_slots(slots),
    do: Enum.filter(slots, fn {_s, _e, status} -> status == :available end)

  defp selected_label(%Service{time_unit: unit} = service, {:dates, starts_on, ends_on})
       when unit in ["day", "night"] do
    n = Date.diff(ends_on, starts_on)
    word = if unit == "night", do: "night(s)", else: "day(s)"

    "#{Calendar.strftime(starts_on, "%d %b %Y")} → #{Calendar.strftime(ends_on, "%d %b %Y")} · #{n} #{word} · #{service.name}"
  end

  defp selected_label(_service, {starts_at, ends_at}) do
    start_f = Engine.utc_to_frame(starts_at)
    end_f = Engine.utc_to_frame(ends_at)

    "#{Calendar.strftime(start_f, "%d %b %Y %H:%M")} – #{Calendar.strftime(end_f, "%H:%M")}"
  end

  defp selected_label(_service, _), do: ""

  defp next_open_days_note(day_capacity) do
    open = Enum.count(day_capacity, fn {_d, n} -> n > 0 end)
    "#{open} open day(s) in the current booking window."
  end
end
