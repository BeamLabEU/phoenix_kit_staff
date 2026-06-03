defmodule PhoenixKitStaff.Web.TeamsLive do
  @moduledoc "List teams across all departments."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, Paths, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Web.Helpers

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

  def handle_info(msg, socket) do
    Logger.debug("[Staff] TeamsLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

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

          {:error, reason} ->
            Helpers.log_operation_error("staff.team_deleted", socket,
              reason: reason,
              resource_type: "team",
              resource_uuid: team.uuid,
              metadata: %{"name" => team.name}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete team."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <.admin_page_header
        title={gettext("Teams")}
        subtitle={gettext("Teams across all departments.")}
      >
        <:actions>
          <.link navigate={Paths.new_team()} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New team")}
          </.link>
        </:actions>
      </.admin_page_header>

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
                  <th>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</th>
                  <th>{gettext("Department")}</th>
                  <th class="text-right">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</th>
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
                      phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
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
