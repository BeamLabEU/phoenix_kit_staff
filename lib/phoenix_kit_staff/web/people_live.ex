defmodule PhoenixKitStaff.Web.PeopleLive do
  @moduledoc "List staff."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitStaff.{Activity, Paths, Staff}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Person

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_people())

    {:ok,
     socket
     |> assign(page_title: gettext("Staff"), search: "", status: "")
     |> load_people()}
  end

  @impl true
  def handle_info({:staff, _event, _payload}, socket), do: {:noreply, load_people(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_people(socket) do
    assign(socket,
      people:
        Staff.list_people(
          search: socket.assigns.search,
          status: socket.assigns.status
        )
    )
  end

  @impl true
  def handle_event("filter", %{"search" => s, "status" => st}, socket) do
    {:noreply, socket |> assign(search: s, status: st) |> load_people()}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, socket |> assign(search: "", status: "") |> load_people()}
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Staff.get_person(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Staff not found."))}

      person ->
        case Staff.delete_person(person) do
          {:ok, _} ->
            Activity.log("staff.person_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "staff_person",
              resource_uuid: person.uuid,
              target_uuid: person.user_uuid,
              metadata: %{}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Staff removed."))
             |> load_people()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not remove staff."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Staff")}</h1>
          <p class="text-sm text-base-content/60">{gettext("Everyone on staff, linked to their PhoenixKit user.")}</p>
        </div>
        <.link navigate={Paths.new_person()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New staff")}
        </.link>
      </div>

      <div class="bg-base-200 rounded-lg p-3">
        <.form for={%{}} phx-change="filter" class="flex flex-wrap gap-3 items-end">
          <.input
            name="search"
            label={gettext("Search")}
            type="search"
            value={@search}
            placeholder={gettext("search by email")}
          />
          <.select
            name="status"
            label={gettext("Status")}
            value={@status}
            options={[{gettext("All"), ""}, {gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
          />
          <button type="button" phx-click="clear" class="btn btn-ghost btn-sm">{gettext("Clear")}</button>
        </.form>
      </div>

      <%= if @people == [] do %>
        <div class="text-center py-16 text-base-content/60">
          <.icon name="hero-identification" class="w-12 h-12 mx-auto mb-2 opacity-40" />
          <p>{gettext("No staff match.")}</p>
        </div>
      <% else %>
        <div class="card bg-base-100 shadow">
          <div class="card-body p-0">
            <table class="table">
              <thead>
                <tr>
                  <th>{gettext("User")}</th>
                  <th>{gettext("Title")}</th>
                  <th>{gettext("Primary dept")}</th>
                  <th>{gettext("Status")}</th>
                  <th class="text-right">{gettext("Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={p <- @people} class="hover">
                  <td>
                    <.link navigate={Paths.person(p.uuid)} class="link link-hover font-medium">
                      {p.user && p.user.email || "—"}
                    </.link>
                  </td>
                  <td class="text-sm">{p.job_title || "—"}</td>
                  <td>{p.primary_department && p.primary_department.name || "—"}</td>
                  <td>
                    <span class={"badge badge-sm #{status_badge_class(p.status)}"}>{Person.status_label(p.status)}</span>
                  </td>
                  <td class="text-right">
                    <.link navigate={Paths.edit_person(p.uuid)} class="btn btn-ghost btn-xs">
                      <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                    </.link>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-uuid={p.uuid}
                      phx-disable-with={gettext("Removing…")}
                      data-confirm={gettext("Remove this staff? The user account stays; only the staff profile is removed.")}
                      class="btn btn-ghost btn-xs text-error"
                    >
                      <.icon name="hero-trash" class="w-3.5 h-3.5" />
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("inactive"), do: "badge-ghost"
  defp status_badge_class(_), do: "badge-ghost"
end
