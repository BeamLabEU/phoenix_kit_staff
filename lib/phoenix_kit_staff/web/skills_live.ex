defmodule PhoenixKitStaff.Web.SkillsLive do
  @moduledoc "List skills."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, L10n, Paths, Skills}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Skill
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_skills())

    {:ok,
     socket
     |> assign(Helpers.section_assigns())
     |> assign(
       page_title: gettext("Skills"),
       page_subtitle: gettext("Skills you can assign to staff.")
     )
     |> load_skills()}
  end

  defp load_skills(socket) do
    assign(socket, skills: Skills.list(), person_counts: Skills.person_counts())
  end

  @impl true
  def handle_info({:staff, _event, _payload}, socket) do
    {:noreply, load_skills(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[Staff] SkillsLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Skills.get(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Skill not found."))}

      skill ->
        case Skills.delete(skill) do
          {:ok, _} ->
            Activity.log("staff.skill_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "skill",
              resource_uuid: skill.uuid,
              metadata: %{"name" => skill.name}
            )

            {:noreply, socket |> put_flash(:info, gettext("Skill deleted.")) |> load_skills()}

          {:error, reason} ->
            Helpers.log_operation_error("staff.skill_deleted", socket,
              reason: reason,
              resource_type: "skill",
              resource_uuid: skill.uuid,
              metadata: %{"name" => skill.name}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete skill."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :lang, L10n.current_content_lang())

    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <.table_default id="skills-list" variant="zebra" size="sm">
        <:toolbar_primary>
          <.button
            size="sm"
            navigate={Paths.new_skill()}
            title={gettext("New skill")}
            aria-label={gettext("New skill")}
          >
            <.icon name="hero-plus" class="h-4 w-4" />
            <span class="hidden sm:inline">{gettext("New skill")}</span>
          </.button>
        </:toolbar_primary>
        <.table_default_header>
          <.table_default_row>
          <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</.table_default_header_cell>
          <.table_default_header_cell>{gettext("People")}</.table_default_header_cell>
          <.table_default_header_cell class="text-right w-px whitespace-nowrap">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}
          </.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :if={@skills == []}>
            <.table_default_cell colspan={3}>
              <.empty_state icon="hero-academic-cap" title={gettext("No skills yet.")}>
                <:cta>
                  <.button size="sm" navigate={Paths.new_skill()}>
                    {gettext("Create your first skill")}
                  </.button>
                </:cta>
              </.empty_state>
            </.table_default_cell>
          </.table_default_row>
          <.table_default_row :for={skill <- @skills}>
          <.table_default_cell>
              <.link navigate={Paths.skill(skill.uuid)} class="link link-hover font-medium">
                {Skill.localized_name(skill, @lang)}
              </.link>
          </.table_default_cell>
          <.table_default_cell>
            {Map.get(@person_counts, skill.uuid, 0)}
          </.table_default_cell>
          <.table_default_cell class="text-right w-px whitespace-nowrap">
              <.table_row_menu id={"skill-menu-#{skill.uuid}"}>
                <.table_row_menu_link
                  navigate={Paths.skill(skill.uuid)}
                  icon="hero-eye"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                />
                <.table_row_menu_link
                  navigate={Paths.edit_skill(skill.uuid)}
                  icon="hero-pencil"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                  variant="secondary"
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="delete"
                  phx-value-uuid={skill.uuid}
                  phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
                  data-confirm={
                    gettext("Delete skill %{name}? It will be removed from %{count} people.",
                    name: Skill.localized_name(skill, @lang),
                    count: Map.get(@person_counts, skill.uuid, 0)
                  )
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
