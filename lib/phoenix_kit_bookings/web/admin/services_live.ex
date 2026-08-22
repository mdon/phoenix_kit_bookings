defmodule PhoenixKitBookings.Web.Admin.ServicesLive do
  @moduledoc """
  Admin list of bookable services: create, activate/deactivate, trash /
  restore / permanently delete, jump to the edit form. Live — subscribes
  to the services topic so config changes from other sessions re-render.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKitBookings.{Errors, Paths, Policy}
  alias PhoenixKitBookings.Schemas.Service
  alias PhoenixKitBookings.Services
  alias PhoenixKitBookings.Web.Format

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      case PhoenixKit.Config.pubsub_server() do
        nil -> :ok
        pubsub -> Phoenix.PubSub.subscribe(pubsub, Services.services_topic())
      end
    end

    {:ok, assign(socket, page_title: gettext("Services"), filter: "all")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = if params["status"] in Service.statuses(), do: params["status"], else: "all"
    {:noreply, socket |> assign(filter: filter) |> load_services()}
  end

  defp load_services(socket) do
    scope = scope(socket)

    services =
      case socket.assigns.filter do
        "all" -> Policy.visible_services(scope)
        status -> Policy.visible_services(scope, status: status)
      end

    counts =
      scope
      |> Policy.visible_services(include_trashed: true)
      |> Enum.frequencies_by(& &1.status)

    assign(socket,
      services: services,
      counts: counts,
      waitlist_counts: PhoenixKitBookings.Bookings.waitlist_counts(),
      can_create: Policy.can_create?(scope)
    )
  end

  defp scope(socket), do: socket.assigns[:phoenix_kit_current_scope]

  @impl true
  def handle_info({:bookings_service_changed, _uuid}, socket) do
    {:noreply, load_services(socket)}
  end

  @impl true
  def handle_event("set_status", %{"uuid" => uuid, "status" => status}, socket)
      when status in ["active", "inactive"] do
    with %Service{} = service <- Services.get_service(uuid),
         {:ok, updated} <- Policy.set_status(scope(socket), service, status) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("%{name} is now %{status}.", name: updated.name, status: status)
       )
       |> load_services()}
    else
      _ -> {:noreply, put_flash(socket, :error, Errors.message(:unknown))}
    end
  end

  def handle_event("trash", %{"uuid" => uuid}, socket) do
    with %Service{} = service <- Services.get_service(uuid),
         {:ok, updated} <- Policy.trash_service(scope(socket), service) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("%{name} moved to trash.", name: updated.name))
       |> load_services()}
    else
      _ -> {:noreply, put_flash(socket, :error, Errors.message(:unknown))}
    end
  end

  def handle_event("restore", %{"uuid" => uuid}, socket) do
    with %Service{status: "trashed"} = service <- Services.get_service(uuid),
         {:ok, updated} <- Policy.restore_service(scope(socket), service) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("%{name} restored.", name: updated.name))
       |> load_services()}
    else
      _ -> {:noreply, put_flash(socket, :error, Errors.message(:unknown))}
    end
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with %Service{status: "trashed"} = service <- Services.get_service(uuid),
         {:ok, deleted} <- Policy.delete_service(scope(socket), service) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("%{name} permanently deleted.", name: deleted.name))
       |> load_services()}
    else
      _ -> {:noreply, put_flash(socket, :error, Errors.message(:unknown))}
    end
  end

  defp filter_tabs(counts) do
    total = counts |> Map.values() |> Enum.sum()

    [
      %{id: "all", label: gettext("All"), badge: total, patch: filter_patch("all")},
      %{
        id: "active",
        label: gettext("Active"),
        badge: Map.get(counts, "active", 0),
        patch: filter_patch("active")
      },
      %{
        id: "inactive",
        label: gettext("Inactive"),
        badge: Map.get(counts, "inactive", 0),
        patch: filter_patch("inactive")
      },
      %{
        id: "trashed",
        label: gettext("Trash"),
        badge: Map.get(counts, "trashed", 0),
        patch: filter_patch("trashed")
      }
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-2xl font-bold">{gettext("Services")}</h2>
          <p class="text-sm text-base-content/60 mt-1">
            {gettext("Each service defines its own booking shape — daily stays, fixed slots, or free-form times.")}
          </p>
        </div>
        <.link :if={@can_create} navigate={Paths.admin_service_new()} class="btn btn-primary">
          <.icon name="hero-plus" class="w-4 h-4" />
          {gettext("New Service")}
        </.link>
      </div>

      <%!-- Core's <.nav_tabs>, boxed like before. filter_patch/1 URLs are
           already prefixed — :patch passes through verbatim, so the helper
           stays exactly as it was. --%>
      <.nav_tabs class="w-fit" active_tab={@filter} tabs={filter_tabs(@counts)} />

      <div class="card bg-base-100 shadow-lg overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("Name")}</th>
              <th>{gettext("Booking shape")}</th>
              <th>{gettext("Signup")}</th>
              <th>{gettext("Status")}</th>
              <th class="text-right">{gettext("Actions")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={service <- @services} id={"service-#{service.uuid}"}>
              <td>
                <.link
                  navigate={Paths.admin_service_edit(service.uuid)}
                  class="link link-hover font-medium"
                >
                  {service.name}
                </.link>
                <div class="text-xs text-base-content/50">/{service.slug}</div>
              </td>
              <td class="text-sm">
                {Format.mode_summary(service)}
                <div :if={@waitlist_counts[service.uuid]} class="text-xs text-warning">
                  {gettext("%{count} on waitlist", count: @waitlist_counts[service.uuid])}
                </div>
              </td>
              <td class="text-sm">
                {signup_label(service)}
              </td>
              <td><span class={Format.service_badge(service.status)}>{service.status}</span></td>
              <td class="text-right">
                <div class="join">
                  <button
                    :if={service.status == "active"}
                    class="btn btn-xs join-item"
                    phx-click="set_status"
                    phx-value-uuid={service.uuid}
                    phx-value-status="inactive"
                  >
                    {gettext("Deactivate")}
                  </button>
                  <button
                    :if={service.status == "inactive"}
                    class="btn btn-xs join-item"
                    phx-click="set_status"
                    phx-value-uuid={service.uuid}
                    phx-value-status="active"
                  >
                    {gettext("Activate")}
                  </button>
                  <button
                    :if={service.status != "trashed"}
                    class="btn btn-xs btn-ghost join-item"
                    phx-click="trash"
                    phx-value-uuid={service.uuid}
                    data-confirm={gettext("Move this service to trash? Its bookings stay.")}
                  >
                    {gettext("Trash")}
                  </button>
                  <button
                    :if={service.status == "trashed"}
                    class="btn btn-xs join-item"
                    phx-click="restore"
                    phx-value-uuid={service.uuid}
                  >
                    {gettext("Restore")}
                  </button>
                  <button
                    :if={service.status == "trashed"}
                    class="btn btn-xs btn-error join-item"
                    phx-click="delete"
                    phx-value-uuid={service.uuid}
                    data-confirm={gettext("Permanently delete this service AND all of its bookings?")}
                  >
                    {gettext("Delete")}
                  </button>
                </div>
              </td>
            </tr>
            <tr :if={@services == []}>
              <td colspan="5" class="text-center text-base-content/50 py-8">
                {gettext("No services yet. Create one to start taking bookings.")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp filter_patch("all"), do: Paths.admin_services()
  defp filter_patch(status), do: Paths.admin_services() <> "?status=#{status}"

  defp signup_label(%Service{signup_policy: "login_required"}), do: gettext("Login required")

  defp signup_label(%Service{require_approval: true}),
    do: gettext("Anyone · needs approval")

  defp signup_label(_), do: gettext("Anyone")
end
