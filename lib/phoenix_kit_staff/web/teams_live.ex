defmodule PhoenixKitStaff.Web.TeamsLive do
  @moduledoc "List teams across all departments."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitStaff.{Activity, Paths, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_teams())
    {:ok, assign(socket, page_title: gettext("Teams")) |> load_teams()}
  end

  defp load_teams(socket), do: assign(socket, teams: Teams.list())

  @impl true
  def handle_info({:staff, _event, _payload}, socket) do
    {:noreply, load_teams(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Teams.get(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Team not found."))}

      team ->
        case Teams.delete(team) do
          {:ok, _} ->
            Activity.log("staff.team_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "team",
              resource_uuid: team.uuid,
              metadata: %{"name" => team.name}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Team deleted."))
             |> load_teams()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete team."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-4">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Teams")}</h1>
          <p class="text-sm text-base-content/60">{gettext("Teams across all departments.")}</p>
        </div>
        <.link navigate={Paths.new_team()} class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New team")}
        </.link>
      </div>

      <%= if @teams == [] do %>
        <div class="text-center py-16 text-base-content/60">
          <.icon name="hero-user-group" class="w-12 h-12 mx-auto mb-2 opacity-40" />
          <p>{gettext("No teams yet.")}</p>
          <.link navigate={Paths.new_team()} class="link link-primary text-sm">
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
                  <th>{gettext("Department")}</th>
                  <th class="text-right">{gettext("Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={team <- @teams} class="hover">
                  <td>
                    <.link navigate={Paths.team(team.uuid)} class="link link-hover font-medium">
                      {team.name}
                    </.link>
                  </td>
                  <td>
                    <.link navigate={Paths.department(team.department.uuid)} class="text-sm">
                      {team.department.name}
                    </.link>
                  </td>
                  <td class="text-right">
                    <.link
                      navigate={Paths.edit_team(team.uuid)}
                      class="btn btn-ghost btn-xs"
                    >
                      <.icon name="hero-pencil" class="w-3.5 h-3.5" />
                    </.link>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-uuid={team.uuid}
                      phx-disable-with={gettext("Deleting…")}
                      data-confirm={gettext("Delete team %{name}? This removes all memberships.", name: team.name)}
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
