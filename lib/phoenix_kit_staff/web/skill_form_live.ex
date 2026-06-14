defmodule PhoenixKitStaff.Web.SkillFormLive do
  @moduledoc "Create or edit a skill."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitStaff.{Activity, Paths, Skills}
  alias PhoenixKitStaff.Schemas.Skill
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> mount_multilang()
      |> apply_action(socket.assigns.live_action, params)

    {:ok, socket}
  end

  defp apply_action(socket, :new, _params) do
    skill = %Skill{}

    socket
    |> assign(page_title: gettext("New skill"), skill: skill, live_action: :new)
    |> assign_form(Skills.change(skill))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Skills.get(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Skill not found."))
        |> push_navigate(to: Paths.skills())

      skill ->
        socket
        |> assign(
          page_title: gettext("Edit %{name}", name: skill.name),
          skill: skill,
          live_action: :edit
        )
        |> assign_form(Skills.change(skill))
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("switch_language", %{"lang" => lang}, socket) do
    {:noreply, handle_switch_language(socket, lang)}
  end

  def handle_event("validate", %{"skill" => attrs}, socket) do
    cs =
      socket.assigns.skill
      |> Skills.change(merge_attrs(attrs, socket))
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, cs)}
  end

  def handle_event("save", %{"skill" => attrs}, socket) do
    save(socket, socket.assigns.live_action, merge_attrs(attrs, socket))
  end

  defp merge_attrs(attrs, socket) do
    in_flight = Helpers.in_flight_record(socket, :form, :skill)
    Helpers.merge_translations_attrs(attrs, in_flight, Skill.translatable_fields())
  end

  defp save(socket, :new, attrs) do
    case Skills.create(attrs) do
      {:ok, skill} ->
        Activity.log("staff.skill_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "skill",
          resource_uuid: skill.uuid,
          metadata: %{"name" => skill.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Skill created."))
         |> push_navigate(to: Paths.skill(skill.uuid))}

      {:error, cs} ->
        Helpers.log_operation_error("staff.skill_created", socket,
          reason: cs,
          resource_type: "skill",
          metadata: %{"attempted_name" => attrs["name"]}
        )

        {:noreply,
         socket
         |> Helpers.maybe_switch_to_primary_on_error(cs, [:name, :description])
         |> assign_form(cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Skills.update(socket.assigns.skill, attrs) do
      {:ok, skill} ->
        Activity.log("staff.skill_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "skill",
          resource_uuid: skill.uuid,
          metadata: %{"name" => skill.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Skill updated."))
         |> push_navigate(to: Paths.skill(skill.uuid))}

      {:error, cs} ->
        Helpers.log_operation_error("staff.skill_updated", socket,
          reason: cs,
          resource_type: "skill",
          resource_uuid: socket.assigns.skill.uuid,
          metadata: %{"attempted_name" => attrs["name"]}
        )

        {:noreply,
         socket
         |> Helpers.maybe_switch_to_primary_on_error(cs, [:name, :description])
         |> assign_form(cs)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <.admin_page_header
        title={@page_title}
        subtitle={
          if @live_action == :new,
            do: gettext("Create a new skill."),
            else: gettext("Update skill details.")
        }
      />

      <div class="card bg-base-100 shadow max-w-3xl mx-auto w-full">
        <.form for={@form} id="skill-form" phx-change="validate" phx-submit="save" phx-debounce="300">
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
          >
            <div class="card-body flex flex-col gap-3">
              <.translatable_field
                field_name="name"
                form_prefix="skill"
                changeset={@form.source}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"skill[translations][#{@current_lang}][name]"}
                lang_data_key="name"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}
                required
              />

              <.translatable_field
                field_name="description"
                form_prefix="skill"
                changeset={@form.source}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"skill[translations][#{@current_lang}][description]"}
                lang_data_key="description"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}
                type="textarea"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body pt-0">
            <div class="flex justify-end gap-2 mt-2">
              <.link navigate={Paths.skills()} class="btn btn-ghost btn-sm">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}
              </.link>
              <button
                type="submit"
                phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Saving…")}
                class="btn btn-primary btn-sm"
              >
                <%= if @live_action == :new, do: gettext("Create"), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Save") %>
              </button>
            </div>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
