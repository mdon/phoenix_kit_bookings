defmodule PhoenixKitBookings.Web.Admin.BookingsLive do
  @moduledoc """
  Admin reservations list: status filter tabs (pending is the approval
  queue), confirm/cancel actions, live updates via the admin PubSub topic.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKitBookings.{Bookings, Errors, Policy}
  alias PhoenixKitBookings.Web.Format

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      case PhoenixKit.Config.pubsub_server() do
        nil -> :ok
        pubsub -> Phoenix.PubSub.subscribe(pubsub, Bookings.admin_topic())
      end
    end

    {:ok, assign(socket, page_title: gettext("Reservations"), filter: "upcoming")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter =
      if params["filter"] in ["upcoming", "pending", "confirmed", "cancelled", "all"],
        do: params["filter"],
        else: "upcoming"

    {:noreply, socket |> assign(filter: filter) |> load_bookings()}
  end

  defp load_bookings(socket) do
    scope = scope(socket)

    opts =
      case socket.assigns.filter do
        "upcoming" -> [upcoming: true]
        "all" -> []
        status -> [status: status]
      end

    visible = Policy.visible_services(scope, include_trashed: true)
    services = Map.new(visible, &{&1.uuid, &1})

    # Site-wide managers see everything; base-permission holders only the
    # reservations of their own services.
    opts =
      if Policy.manage_all?(scope),
        do: opts,
        else: Keyword.put(opts, :service_uuids, Enum.map(visible, & &1.uuid))

    count_opts =
      if Policy.manage_all?(scope), do: [], else: [service_uuids: Enum.map(visible, & &1.uuid)]

    bookings = Bookings.list_bookings(opts)

    unit_names =
      bookings
      |> Enum.map(& &1.unit_uuid)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> %{}
        uuids -> PhoenixKitBookings.Services.unit_names(uuids)
      end

    assign(socket,
      bookings: bookings,
      services: services,
      unit_names: unit_names,
      counts: Bookings.count_by_status(count_opts)
    )
  end

  defp scope(socket), do: socket.assigns[:phoenix_kit_current_scope]

  @impl true
  def handle_info({:bookings_changed, _service_uuid}, socket) do
    {:noreply, load_bookings(socket)}
  end

  @impl true
  def handle_event("confirm", %{"uuid" => uuid}, socket) do
    with %{status: "pending"} = booking <- Bookings.get_booking(uuid),
         {:ok, _} <- Policy.confirm_booking(scope(socket), booking) do
      {:noreply, socket |> put_flash(:info, gettext("Booking confirmed.")) |> load_bookings()}
    else
      _ -> {:noreply, put_flash(socket, :error, Errors.message(:unknown))}
    end
  end

  def handle_event("cancel", %{"uuid" => uuid}, socket) do
    with %{} = booking <- Bookings.get_booking(uuid),
         {:ok, _} <- Policy.cancel_booking(scope(socket), booking) do
      {:noreply, socket |> put_flash(:info, gettext("Booking cancelled.")) |> load_bookings()}
    else
      {:error, reason, _} -> {:noreply, put_flash(socket, :error, Errors.message(reason))}
      _ -> {:noreply, put_flash(socket, :error, Errors.message(:unknown))}
    end
  end

  defp filter_tabs(counts) do
    total = counts |> Map.values() |> Enum.sum()

    [
      %{id: "upcoming", label: gettext("Upcoming"), badge: nil, patch: filter_patch("upcoming")},
      %{
        id: "pending",
        label: gettext("Pending"),
        badge: Map.get(counts, "pending", 0),
        patch: filter_patch("pending")
      },
      %{
        id: "confirmed",
        label: gettext("Confirmed"),
        badge: Map.get(counts, "confirmed", 0),
        patch: filter_patch("confirmed")
      },
      %{
        id: "cancelled",
        label: gettext("Cancelled"),
        badge: Map.get(counts, "cancelled", 0),
        patch: filter_patch("cancelled")
      },
      %{id: "all", label: gettext("All"), badge: total, patch: filter_patch("all")}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <div>
        <h2 class="text-2xl font-bold">{gettext("Reservations")}</h2>
        <p class="text-sm text-base-content/60 mt-1">
          {gettext("All bookings across services. Pending entries hold their seat until approved or declined.")}
        </p>
      </div>

      <%!-- Core's <.nav_tabs>, boxed like before. filter_patch/1 URLs are
           already prefixed — :patch passes through verbatim, so the helper
           stays exactly as it was. --%>
      <.nav_tabs class="w-fit" active_tab={@filter} tabs={filter_tabs(@counts)} />

      <div class="card bg-base-100 shadow-lg overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("When")}</th>
              <th>{gettext("Service")}</th>
              <th>{gettext("Customer")}</th>
              <th>{gettext("Status")}</th>
              <th class="text-right">{gettext("Actions")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={booking <- @bookings} id={"booking-#{booking.uuid}"}>
              <td class="text-sm whitespace-nowrap">{Format.format_range(booking)}</td>
              <td class="text-sm">
                {service_name(@services, booking.service_uuid)}
                <div :if={@unit_names[booking.unit_uuid]} class="text-xs text-base-content/50">
                  {@unit_names[booking.unit_uuid]}
                </div>
                <div :if={booking.total_price} class="text-xs text-base-content/50">
                  {PhoenixKitBookings.Pricing.format(booking.total_price, booking.currency)}
                </div>
              </td>
              <td class="text-sm">
                <div>{booking.customer_name}</div>
                <div class="text-xs text-base-content/50">{booking.customer_email}</div>
              </td>
              <td>
                <span class={Format.status_badge(booking.status)}>{booking.status}</span>
                <div :if={booking.source == "admin"} class="text-xs text-base-content/50">
                  {gettext("by admin")}
                </div>
              </td>
              <td class="text-right">
                <div class="join">
                  <button
                    :if={booking.status == "pending"}
                    class="btn btn-xs btn-success join-item"
                    phx-click="confirm"
                    phx-value-uuid={booking.uuid}
                  >
                    {gettext("Approve")}
                  </button>
                  <button
                    :if={booking.status in ["pending", "confirmed"]}
                    class="btn btn-xs btn-ghost join-item"
                    phx-click="cancel"
                    phx-value-uuid={booking.uuid}
                    data-confirm={gettext("Cancel this booking?")}
                  >
                    {gettext("Cancel")}
                  </button>
                </div>
              </td>
            </tr>
            <tr :if={@bookings == []}>
              <td colspan="5" class="text-center text-base-content/50 py-8">
                {gettext("No bookings match this view.")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp filter_patch("upcoming"), do: PhoenixKitBookings.Paths.admin_reservations()

  defp filter_patch(filter),
    do: PhoenixKitBookings.Paths.admin_reservations() <> "?filter=#{filter}"

  defp service_name(services, uuid) do
    case services[uuid] do
      nil -> "—"
      service -> service.name
    end
  end
end
