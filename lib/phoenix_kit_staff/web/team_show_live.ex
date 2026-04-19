defmodule PhoenixKitStaff.Web.TeamShowLive do
  @moduledoc "Show a team and manage its memberships."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitStaff.{Activity, Paths, Staff, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Teams.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Team not found."))
         |> push_navigate(to: Paths.teams())}

      team ->
        if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_team(team.uuid))

        {:ok,
         socket
         |> assign(page_title: team.name, team: team)
         |> load_memberships()}
    end
  end

  @impl true
  def handle_info({:staff, :team_deleted, _}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This team was deleted."))
     |> push_navigate(to: Paths.teams())}
  end

  def handle_info({:staff, _event, _payload}, socket) do
    case Teams.get(socket.assigns.team.uuid) do
      nil ->
        {:noreply, push_navigate(socket, to: Paths.teams())}

      team ->
        {:noreply, socket |> assign(team: team) |> load_memberships()}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_memberships(socket) do
    team_uuid = socket.assigns.team.uuid

    assign(socket,
      memberships: Staff.list_team_memberships(team_uuid),
      available_people: Staff.people_not_on_team(team_uuid),
      add_form: to_form(%{"staff_person_uuid" => ""})
    )
  end

  @impl true
  def handle_event("add_person", %{"staff_person_uuid" => person_uuid}, socket)
      when person_uuid != "" do
    case Staff.add_team_person(socket.assigns.team.uuid, person_uuid) do
      {:ok, tm} ->
        Activity.log("staff.team_person_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "team",
          resource_uuid: socket.assigns.team.uuid,
          target_uuid: person_uuid,
          metadata: %{"team_membership_uuid" => tm.uuid}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Staff added."))
         |> load_memberships()}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, gettext("Could not add staff."))}
    end
  end

  def handle_event("add_person", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick someone first."))}
  end

  def handle_event("remove_person", %{"uuid" => tm_uuid}, socket) do
    case Enum.find(socket.assigns.memberships, &(&1.uuid == tm_uuid)) do
      nil ->
        {:noreply, socket}

      tm ->
        case Staff.remove_team_person(tm) do
          {:ok, _} ->
            Activity.log("staff.team_person_removed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "team",
              resource_uuid: socket.assigns.team.uuid,
              target_uuid: tm.staff_person_uuid,
              metadata: %{}
            )

            {:noreply, load_memberships(socket) |> put_flash(:info, gettext("Staff removed."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not remove staff from team."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-4xl px-4 py-6 gap-4">
      <div>
        <.link navigate={Paths.teams()} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Teams")}
        </.link>
        <div class="flex items-center justify-between mt-1">
          <h1 class="text-2xl font-bold">{@team.name}</h1>
          <.link navigate={Paths.edit_team(@team.uuid)} class="btn btn-ghost btn-sm">
            <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Edit")}
          </.link>
        </div>
        <div class="text-sm text-base-content/60 mt-1">
          <.link navigate={Paths.department(@team.department.uuid)} class="link link-hover">
            {@team.department.name}
          </.link>
          <span :if={@team.description} class="ml-2">— {@team.description}</span>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-lg">{gettext("Add staff")}</h2>
          <%= if @available_people == [] do %>
            <p class="text-sm text-base-content/60">
              {gettext("Everyone is already on this team (or there are no staff yet —")} <.link navigate={Paths.new_person()} class="link link-primary">{gettext("create one")}</.link>).
            </p>
          <% else %>
            <.form for={@add_form} phx-submit="add_person" class="flex flex-wrap gap-2 items-end">
              <.select
                field={@add_form[:staff_person_uuid]}
                label={gettext("Staff")}
                options={Enum.map(@available_people, &{person_label(&1), &1.uuid})}
                prompt={gettext("Select staff")}
              />
              <button type="submit" phx-disable-with={gettext("Adding…")} class="btn btn-primary btn-sm">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add")}
              </button>
            </.form>
          <% end %>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-lg">{gettext("Staff")} ({length(@memberships)})</h2>
          <%= if @memberships == [] do %>
            <p class="text-sm text-base-content/60 py-4">{gettext("No staff on this team yet.")}</p>
          <% else %>
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Staff")}</th>
                  <th class="text-right"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={tm <- @memberships}>
                  <td>
                    <.link navigate={Paths.person(tm.staff_person.uuid)} class="link link-hover">
                      {person_label(tm.staff_person)}
                    </.link>
                  </td>
                  <td class="text-right">
                    <button
                      type="button"
                      phx-click="remove_person"
                      phx-value-uuid={tm.uuid}
                      data-confirm={gettext("Remove this staff from the team?")}
                      class="btn btn-ghost btn-xs text-error"
                    >
                      <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp person_label(%{user: %{email: email}}), do: email
  defp person_label(_), do: "—"
end
