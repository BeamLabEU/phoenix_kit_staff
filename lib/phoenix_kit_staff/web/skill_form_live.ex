defmodule PhoenixKitStaff.Web.SkillFormLive do
  @moduledoc """
  Create or edit a skill, including its per-skill proficiency levels.

  The levels editor is **staged in `@staged_levels`** (the source of truth) and
  rendered inside `#skill-form` but **outside** `<.multilang_fields_wrapper>`,
  so it survives language switches (the wrapper re-mounts its subtree on switch).
  Each level-name input's DOM `id` is keyed on `@current_lang` so morphdom
  replaces the node on a switch and the value refreshes to the active language;
  `validate` merges only the active language's typed names back into the staged
  list. Structural edits (add / seed / reorder / remove) are event-driven so a
  reconnect can't strand them. On save the staged list is injected as
  `attrs["levels"]` and normalised by `Skill.changeset/2`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitStaff.{Activity, Paths, Skills}
  alias PhoenixKitStaff.Schemas.Skill
  alias PhoenixKitStaff.Web.Helpers

  # Convenience seed for the common beginner→expert ladder (et/ru pre-filled;
  # editable + translatable after). Primary name is English — rename if the
  # app's primary language differs.
  @standard_levels [
    {"Beginner", %{"et" => "Algaja", "ru" => "Начинающий"}},
    {"Intermediate", %{"et" => "Kesktase", "ru" => "Средний"}},
    {"Advanced", %{"et" => "Edasijõudnu", "ru" => "Продвинутый"}},
    {"Expert", %{"et" => "Ekspert", "ru" => "Эксперт"}}
  ]

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
    |> assign(
      page_title: gettext("New skill"),
      skill: skill,
      live_action: :new,
      staged_levels: [],
      allow_multiple: false
    )
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
          live_action: :edit,
          staged_levels: Skill.levels(skill),
          allow_multiple: skill.allow_multiple_levels
        )
        |> assign_form(Skills.change(skill))
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("switch_language", %{"lang" => lang}, socket) do
    {:noreply, handle_switch_language(socket, lang)}
  end

  def handle_event("validate", %{"skill" => attrs} = params, socket) do
    staged = merge_level_names(socket.assigns.staged_levels, params["level"], socket)
    allow_multiple = parse_bool(attrs["allow_multiple_levels"])

    cs =
      socket.assigns.skill
      |> Skills.change(build_attrs(attrs, socket, staged))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(staged_levels: staged, allow_multiple: allow_multiple)
     |> assign_form(cs)}
  end

  def handle_event("save", %{"skill" => attrs} = params, socket) do
    staged = merge_level_names(socket.assigns.staged_levels, params["level"], socket)
    socket = assign(socket, :staged_levels, staged)
    save(socket, socket.assigns.live_action, build_attrs(attrs, socket, staged))
  end

  def handle_event("add_level", _params, socket) do
    {:noreply, assign(socket, :staged_levels, socket.assigns.staged_levels ++ [new_level()])}
  end

  def handle_event("seed_standard_levels", _params, socket) do
    seeded =
      Enum.map(@standard_levels, fn {name, translations} ->
        %{"id" => Skill.gen_level_id(), "name" => name, "translations" => translations}
      end)

    {:noreply, assign(socket, :staged_levels, socket.assigns.staged_levels ++ seeded)}
  end

  def handle_event("remove_level", %{"id" => id}, socket) do
    staged = Enum.reject(socket.assigns.staged_levels, &(&1["id"] == id))
    {:noreply, assign(socket, :staged_levels, staged)}
  end

  def handle_event("move_level_up", %{"id" => id}, socket) do
    {:noreply, assign(socket, :staged_levels, move_level(socket.assigns.staged_levels, id, -1))}
  end

  def handle_event("move_level_down", %{"id" => id}, socket) do
    {:noreply, assign(socket, :staged_levels, move_level(socket.assigns.staged_levels, id, 1))}
  end

  # Inject the staged levels into the skill attrs (the editor is the source of
  # truth, not a `skill[...]` form field) and fold in-flight translations.
  defp build_attrs(attrs, socket, staged) do
    attrs
    |> merge_attrs(socket)
    |> Map.put("levels", staged)
  end

  defp merge_attrs(attrs, socket) do
    in_flight = Helpers.in_flight_record(socket, :form, :skill)
    Helpers.merge_translations_attrs(attrs, in_flight, Skill.translatable_fields())
  end

  # Merge the active language's typed level names back into the staged list.
  # Only keys present in params are touched (a non-active language's names are
  # held in the staged list, untouched).
  defp merge_level_names(staged, nil, _socket), do: staged

  defp merge_level_names(staged, params, socket) when is_map(params) do
    lang = socket.assigns.current_lang
    primary? = lang == socket.assigns.primary_language

    Enum.map(staged, fn level ->
      case params[level["id"]] do
        %{"name" => typed} -> put_level_name(level, typed, lang, primary?)
        _ -> level
      end
    end)
  end

  defp merge_level_names(staged, _params, _socket), do: staged

  defp put_level_name(level, typed, _lang, true), do: Map.put(level, "name", typed)

  defp put_level_name(level, typed, lang, false) do
    translations =
      level
      |> Map.get("translations", %{})
      |> then(fn t ->
        if String.trim(typed) == "", do: Map.delete(t, lang), else: Map.put(t, lang, typed)
      end)

    Map.put(level, "translations", translations)
  end

  defp new_level, do: %{"id" => Skill.gen_level_id(), "name" => "", "translations" => %{}}

  defp move_level(levels, id, delta) do
    case Enum.find_index(levels, &(&1["id"] == id)) do
      nil ->
        levels

      idx ->
        target = idx + delta

        if target >= 0 and target < length(levels) do
          a = Enum.at(levels, idx)
          b = Enum.at(levels, target)

          levels
          |> List.replace_at(idx, b)
          |> List.replace_at(target, a)
        else
          levels
        end
    end
  end

  defp parse_bool("true"), do: true
  defp parse_bool(true), do: true
  defp parse_bool(_), do: false

  # The level-name input value for the active language: the primary `name` on
  # the primary tab, else the `translations[lang]` override.
  defp level_field_value(level, lang, lang), do: Map.get(level, "name", "")

  defp level_field_value(level, lang, _primary),
    do: level |> Map.get("translations", %{}) |> Map.get(lang, "")

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

          <%!-- Levels editor — inside the form, OUTSIDE the multilang wrapper
               (structure is shared across languages; only the per-level name is
               translatable, edited for the active language). --%>
          <div class="card-body border-t border-base-200 pt-4 flex flex-col gap-4">
            <div>
              <label class="label cursor-pointer justify-start gap-3 p-0">
                <input type="hidden" name="skill[allow_multiple_levels]" value="false" />
                <input
                  type="checkbox"
                  name="skill[allow_multiple_levels]"
                  value="true"
                  checked={@allow_multiple}
                  class="toggle toggle-primary"
                />
                <span class="label-text font-semibold">{gettext("Allow selecting multiple levels")}</span>
              </label>
              <p class="text-xs text-base-content/50 mt-1">
                {gettext("On: a person can hold several of these levels at once (e.g. licence categories). Off: a single level.")}
              </p>
            </div>

            <div>
              <label class="label mb-2">
                <span class="label-text font-semibold">
                  {gettext("Proficiency levels")}
                  <span class="label-text-alt text-base-content/50 font-normal">{gettext("optional")}</span>
                </span>
              </label>

              <p :if={@staged_levels == []} class="text-sm text-base-content/60 mb-2">
                {gettext("No levels — this skill is assigned without a proficiency level. Add some below, or leave empty.")}
              </p>

              <div :if={@staged_levels != []} class="flex flex-col gap-2">
                <div
                  :for={{level, idx} <- Enum.with_index(@staged_levels)}
                  class="flex items-center gap-2"
                >
                  <span class="text-xs text-base-content/40 w-5 text-right tabular-nums">{idx + 1}.</span>
                  <input
                    type="text"
                    id={"level-#{level["id"]}-name-#{@current_lang}"}
                    name={"level[#{level["id"]}][name]"}
                    value={level_field_value(level, @current_lang, @primary_language)}
                    placeholder={
                      if @current_lang == @primary_language,
                        do: gettext("Level name"),
                        else: Map.get(level, "name", gettext("Level name"))
                    }
                    autocomplete="off"
                    class="input input-sm w-full"
                  />
                  <div class="flex items-center shrink-0">
                    <button
                      type="button"
                      phx-click="move_level_up"
                      phx-value-id={level["id"]}
                      disabled={idx == 0}
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label={gettext("Move up")}
                    >
                      <.icon name="hero-chevron-up" class="w-4 h-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="move_level_down"
                      phx-value-id={level["id"]}
                      disabled={idx == length(@staged_levels) - 1}
                      class="btn btn-ghost btn-xs btn-square"
                      aria-label={gettext("Move down")}
                    >
                      <.icon name="hero-chevron-down" class="w-4 h-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="remove_level"
                      phx-value-id={level["id"]}
                      class="btn btn-ghost btn-xs btn-square text-error"
                      aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                </div>
              </div>

              <div class="flex flex-wrap gap-2 mt-2">
                <button type="button" phx-click="add_level" class="btn btn-ghost btn-sm">
                  <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add level")}
                </button>
                <button
                  :if={@staged_levels == []}
                  type="button"
                  phx-click="seed_standard_levels"
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-sparkles" class="w-4 h-4" /> {gettext("Add standard levels")}
                </button>
              </div>
            </div>
          </div>

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
