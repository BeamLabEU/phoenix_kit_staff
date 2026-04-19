defmodule PhoenixKitStaff.Web.DepartmentsLive do
  @moduledoc "List departments."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitStaff.{Activity, Departments, Paths}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_departments())
    {:ok, assign(socket, page_title: gettext("Departments")) |> load_departments()}
  end

  defp load_departments(socket) do
    assign(socket, departments: Departments.list(preload: [:teams]))
  end

  @impl true
  def handle_info({:staff, _event, _payload}, socket) do
    {:noreply, load_departments(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Departments.get(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Department not found."))}

      dept ->
        case Departments.delete(dept) do
          {:ok, _} ->
            Activity.log("staff.department_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "department",
              resource_uuid: dept.uuid,
              metadata: %{"name" => dept.name}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Department deleted."))
             |> load_departments()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete department."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Departments")}</h1>
          <p class="text-sm text-base-content/60">{gettext("Top-level organizational units.")}</p>
        </div>
        <.link navigate={Paths.new_department()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New department")}
        </.link>
      </div>

      <%= if @departments == [] do %>
        <div class="text-center py-16 text-base-content/60">
          <.icon name="hero-building-office-2" class="w-12 h-12 mx-auto mb-2 opacity-40" />
          <p>{gettext("No departments yet.")}</p>
          <.link navigate={Paths.new_department()} class="link link-primary text-sm">
            {gettext("Create your first")}
          </.link>
        </div>
      <% else %>
        <div class="card bg-base-100 shadow">
          <div class="card-body p-0">
            <table class="table">
              <thead>
                <tr>
                  <th>{gettext("Name")}</th>
                  <th>{gettext("Teams")}</th>
                  <th class="text-right">{gettext("Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={dept <- @departments} class="hover">
                  <td>
                    <.link navigate={Paths.department(dept.uuid)} class="link link-hover font-medium">
                      {dept.name}
                    </.link>
                    <div :if={dept.description} class="text-xs text-base-content/60 truncate max-w-md">
                      {dept.description}
                    </div>
                  </td>
                  <td>{length(dept.teams)}</td>
                  <td class="text-right">
                    <.link
                      navigate={Paths.edit_department(dept.uuid)}
                      class="btn btn-ghost btn-xs"
                    >
                      <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                    </.link>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-uuid={dept.uuid}
                      phx-disable-with={gettext("Deleting…")}
                      data-confirm={gettext("Delete department %{name}? This will also delete its teams and memberships.", name: dept.name)}
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
end
