defmodule PhoenixKitStaff.Web.DepartmentShowLive do
  @moduledoc "Show a department with its teams."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Departments, L10n, Paths, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Department, Team}
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Subscribe BEFORE the DB read so a broadcast that fires between
    # `Departments.get/2` and a post-fetch subscribe doesn't get dropped.
    # The URL `id` is the UUID, so the topic key is identical either way.
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_department(id))

    case Departments.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Department not found."))
         |> push_navigate(to: Paths.departments())}

      dept ->
        {:ok,
         socket
         |> assign(dept_header_assigns(dept))
         |> assign(dept: dept, teams: Teams.list(department_uuid: dept.uuid))}
    end
  end

  # Name and description are translatable, so the header assigns are derived
  # together and refreshed on every broadcast alongside `dept` itself —
  # otherwise a rename via PubSub would leave the breadcrumb title stale.
  defp dept_header_assigns(dept) do
    lang = L10n.current_content_lang()

    Helpers.section_assigns() ++
      [
        page_crumbs: [%{label: gettext("Departments"), path: Paths.departments()}],
        page_title: Department.localized_name(dept, lang),
        page_subtitle: Department.localized_description(dept, lang),
        page_action: %{
          icon: "hero-pencil",
          label: Gettext.gettext(PhoenixKitWeb.Gettext, "Edit"),
          navigate: Paths.edit_department(dept.uuid),
          show_label: true
        }
      ]
  end

  @impl true
  def handle_info({:staff, :department_deleted, _}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This department was deleted."))
     |> push_navigate(to: Paths.departments())}
  end

  def handle_info({:staff, _event, _payload}, socket) do
    case Departments.get(socket.assigns.dept.uuid) do
      nil ->
        {:noreply, push_navigate(socket, to: Paths.departments())}

      dept ->
        {:noreply,
         socket
         |> assign(dept_header_assigns(dept))
         |> assign(dept: dept, teams: Teams.list(department_uuid: dept.uuid))}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[Staff] DepartmentShowLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :lang, L10n.current_content_lang())

    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <.form_section title={"#{gettext("Teams")} (#{length(@teams)})"}>
        <:actions>
          <.button size="xs" navigate={Paths.new_team(@dept.uuid)}>
            <.icon name="hero-plus" class="w-3.5 h-3.5" /> {gettext("New team")}
          </.button>
        </:actions>

        <%= if @teams == [] do %>
          <.empty_state
            icon="hero-user-group"
            title={gettext("No teams in this department yet.")}
            class="py-6"
          >
            <:cta>
              <.button size="sm" navigate={Paths.new_team(@dept.uuid)}>
                {gettext("Create your first team")}
              </.button>
            </:cta>
          </.empty_state>
        <% else %>
          <.table_default id={"department-teams-#{@dept.uuid}"} size="sm">
            <.table_default_header>
              <.table_default_row>
                <.table_default_header_cell>
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}
                </.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <.table_default_body>
              <.table_default_row :for={team <- @teams}>
                <.table_default_cell>
                  <.link navigate={Paths.team(team.uuid)} class="link link-hover font-medium">
                    {Team.localized_name(team, @lang)}
                  </.link>
                </.table_default_cell>
              </.table_default_row>
            </.table_default_body>
          </.table_default>
        <% end %>
      </.form_section>
    </div>
    """
  end
end
