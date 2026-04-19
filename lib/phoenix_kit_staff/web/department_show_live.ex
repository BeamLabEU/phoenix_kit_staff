defmodule PhoenixKitStaff.Web.DepartmentShowLive do
  @moduledoc "Show a department with its teams."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitStaff.{Departments, Paths, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Departments.get(id, preload: [:teams]) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Department not found."))
         |> push_navigate(to: Paths.departments())}

      dept ->
        if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_department(dept.uuid))

        {:ok,
         assign(socket,
           page_title: dept.name,
           dept: dept,
           teams: Teams.list(department_uuid: dept.uuid)
         )}
    end
  end

  @impl true
  def handle_info({:staff, :department_deleted, _}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This department was deleted."))
     |> push_navigate(to: Paths.departments())}
  end

  def handle_info({:staff, _event, _payload}, socket) do
    case Departments.get(socket.assigns.dept.uuid, preload: [:teams]) do
      nil ->
        {:noreply, push_navigate(socket, to: Paths.departments())}

      dept ->
        {:noreply, assign(socket, dept: dept, teams: Teams.list(department_uuid: dept.uuid))}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-4xl px-4 py-6 gap-4">
      <div>
        <.link navigate={Paths.departments()} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Departments")}
        </.link>
        <div class="flex items-center justify-between mt-1">
          <h1 class="text-2xl font-bold">{@dept.name}</h1>
          <.link navigate={Paths.edit_department(@dept.uuid)} class="btn btn-ghost btn-sm">
            <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Edit")}
          </.link>
        </div>
        <div :if={@dept.description} class="text-sm text-base-content/60 mt-1">
          {@dept.description}
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-lg">{gettext("Teams")} ({length(@teams)})</h2>
            <.link navigate={Paths.new_team()} class="btn btn-primary btn-xs">
              <.icon name="hero-plus" class="w-3.5 h-3.5" /> {gettext("New team")}
            </.link>
          </div>

          <%= if @teams == [] do %>
            <p class="text-sm text-base-content/60 py-4">{gettext("No teams in this department yet.")}</p>
          <% else %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Name")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={team <- @teams}>
                    <td>
                      <.link navigate={Paths.team(team.uuid)} class="link link-hover font-medium">
                        {team.name}
                      </.link>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
