defmodule PhoenixKitStaff.Web.TeamsLive do
  @moduledoc "List teams across all departments."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, L10n, Paths, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Department, Team}
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_teams())

    {:ok,
     socket
     |> assign(Helpers.section_assigns())
     |> assign(
       page_title: gettext("Teams"),
       page_subtitle: gettext("Teams across all departments.")
     )
     |> load_teams()}
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
    assigns = assign(assigns, :lang, L10n.current_content_lang())

    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <.table_default id="teams-list" variant="zebra" size="sm">
        <:toolbar_primary>
          <.button
            size="sm"
            navigate={Paths.new_team()}
            title={gettext("New team")}
            aria-label={gettext("New team")}
          >
            <.icon name="hero-plus" class="h-4 w-4" />
            <span class="hidden sm:inline">{gettext("New team")}</span>
          </.button>
        </:toolbar_primary>
        <.table_default_header>
          <.table_default_row>
          <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</.table_default_header_cell>
          <.table_default_header_cell>{gettext("Department")}</.table_default_header_cell>
          <.table_default_header_cell class="text-right w-px whitespace-nowrap">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}
          </.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :if={@teams == []}>
            <.table_default_cell colspan={3}>
              <.empty_state icon="hero-user-group" title={gettext("No teams yet.")}>
                <:cta>
                  <.button size="sm" navigate={Paths.new_team()}>
                    {gettext("Create your first team")}
                  </.button>
                </:cta>
              </.empty_state>
            </.table_default_cell>
          </.table_default_row>
          <.table_default_row :for={team <- @teams}>
          <.table_default_cell>
              <.link navigate={Paths.team(team.uuid)} class="link link-hover font-medium">
                {Team.localized_name(team, @lang)}
              </.link>
          </.table_default_cell>
          <.table_default_cell>
            <.link navigate={Paths.department(team.department.uuid)} class="text-sm">
                {Department.localized_name(team.department, @lang)}
              </.link>
          </.table_default_cell>
          <.table_default_cell class="text-right w-px whitespace-nowrap">
              <.table_row_menu id={"team-menu-#{team.uuid}"}>
                <.table_row_menu_link
                  navigate={Paths.team(team.uuid)}
                  icon="hero-eye"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                />
                <.table_row_menu_link
                  navigate={Paths.edit_team(team.uuid)}
                  icon="hero-pencil"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                  variant="secondary"
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="delete"
                  phx-value-uuid={team.uuid}
                  phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
                  data-confirm={
                    gettext("Delete team %{name}? This removes all memberships.", name: Team.localized_name(team, @lang))
                  }
                  icon="hero-trash"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
                  variant="error"
                />
              </.table_row_menu>
          </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>
    </div>
    """
  end
end
