defmodule PhoenixKitStaff.Web.Components.SkillPicker do
  @moduledoc """
  A searchable multi-select for a person's skills, each with a proficiency
  level. Selected skills render as removable chips with an inline level
  dropdown; a type-to-search box filters the remaining skills to add.

  Self-contained LiveComponent: it persists each add/remove/level change
  immediately via `PhoenixKitStaff.Skills` and logs activity (the actor is
  passed in by the host). Render it OUTSIDE the host's `<.form>` (it owns its
  own little search/level forms, which can't nest).

      <.live_component
        module={PhoenixKitStaff.Web.Components.SkillPicker}
        id={"skill-picker-\#{@person.uuid}"}
        person={@person}
        actor_uuid={@actor_uuid}
      />
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitStaff.Gettext

  alias PhoenixKitStaff.{Activity, Skills}
  alias PhoenixKitStaff.Schemas.PersonSkill

  @match_limit 8

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:query, fn -> "" end)
     |> load()}
  end

  defp load(socket) do
    person_uuid = socket.assigns.person.uuid
    assigned = Skills.list_for_person(person_uuid)

    socket
    |> assign(:assigned, assigned)
    |> assign(:matches, matches(socket.assigns[:query] || "", assigned, person_uuid))
  end

  # Skills not yet assigned, filtered by the query (case-insensitive), capped.
  defp matches(query, _assigned, person_uuid) do
    q = query |> to_string() |> String.trim() |> String.downcase()

    person_uuid
    |> Skills.skills_not_assigned_to()
    |> then(fn skills ->
      if q == "",
        do: skills,
        else: Enum.filter(skills, &String.contains?(String.downcase(&1.name), q))
    end)
    |> Enum.take(@match_limit)
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply,
     assign(socket,
       query: q,
       matches: matches(q, socket.assigns.assigned, socket.assigns.person.uuid)
     )}
  end

  def handle_event("add", %{"uuid" => skill_uuid}, socket) do
    person = socket.assigns.person

    case Skills.assign_skill(person.uuid, skill_uuid, nil) do
      {:ok, ps} ->
        log(socket, "staff.person_skill_added", skill_uuid, person.user_uuid, %{
          "person_skill_uuid" => ps.uuid
        })

        {:noreply, socket |> assign(:query, "") |> load()}

      {:error, _} ->
        # Stale match / race — just refresh the list.
        {:noreply, load(socket)}
    end
  end

  def handle_event("set_level", %{"uuid" => ps_uuid, "level" => level}, socket) do
    case Enum.find(socket.assigns.assigned, &(&1.uuid == ps_uuid)) do
      %PersonSkill{} = ps ->
        case Skills.update_assignment_level(ps, level) do
          {:ok, _} ->
            log(
              socket,
              "staff.person_skill_updated",
              ps.skill_uuid,
              socket.assigns.person.user_uuid,
              %{
                "person_skill_uuid" => ps.uuid,
                "proficiency_level" => blank_to_nil(level)
              }
            )

            {:noreply, load(socket)}

          {:error, _} ->
            {:noreply, load(socket)}
        end

      nil ->
        {:noreply, load(socket)}
    end
  end

  def handle_event("remove", %{"uuid" => ps_uuid}, socket) do
    case Enum.find(socket.assigns.assigned, &(&1.uuid == ps_uuid)) do
      %PersonSkill{} = ps ->
        case Skills.unassign_skill(ps) do
          {:ok, _} ->
            log(
              socket,
              "staff.person_skill_removed",
              ps.skill_uuid,
              socket.assigns.person.user_uuid,
              %{}
            )

            {:noreply, load(socket)}

          {:error, _} ->
            {:noreply, load(socket)}
        end

      nil ->
        {:noreply, load(socket)}
    end
  end

  defp log(socket, action, skill_uuid, target_uuid, metadata) do
    Activity.log(action,
      actor_uuid: socket.assigns[:actor_uuid],
      resource_type: "skill",
      resource_uuid: skill_uuid,
      target_uuid: target_uuid,
      metadata: metadata
    )
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-academic-cap" class="w-5 h-5" /> {gettext("Skills")} ({length(@assigned)})
        </h2>

        <%!-- Selected skills as chips, each with an inline level dropdown --%>
        <div :if={@assigned != []} class="flex flex-wrap gap-2">
          <div :for={ps <- @assigned} class="flex items-center gap-1 badge badge-lg badge-outline gap-2 py-4">
            <span class="font-medium">{ps.skill.name}</span>
            <form phx-change="set_level" phx-target={@myself}>
              <input type="hidden" name="uuid" value={ps.uuid} />
              <select name="level" class="select select-xs select-bordered">
                <option value="" selected={is_nil(ps.proficiency_level)}>
                  {PersonSkill.proficiency_label(nil)}
                </option>
                <option
                  :for={lvl <- PersonSkill.proficiency_levels()}
                  value={lvl}
                  selected={ps.proficiency_level == lvl}
                >
                  {PersonSkill.proficiency_label(lvl)}
                </option>
              </select>
            </form>
            <button
              type="button"
              phx-click="remove"
              phx-value-uuid={ps.uuid}
              phx-target={@myself}
              class="btn btn-ghost btn-xs btn-circle text-error"
              aria-label={gettext("Remove")}
            >
              <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
            </button>
          </div>
        </div>

        <%!-- Type-to-search box + matching skills to add --%>
        <div class="relative mt-2 max-w-md">
          <form phx-change="search" phx-target={@myself}>
            <input
              type="text"
              name="q"
              value={@query}
              autocomplete="off"
              phx-debounce="150"
              placeholder={gettext("Type to search skills…")}
              class="input input-bordered input-sm w-full"
            />
          </form>

          <ul
            :if={@matches != []}
            class="menu menu-sm bg-base-100 border border-base-300 rounded-box mt-1 w-full shadow z-10"
          >
            <li :for={skill <- @matches}>
              <button type="button" phx-click="add" phx-value-uuid={skill.uuid} phx-target={@myself}>
                <.icon name="hero-plus" class="w-4 h-4" /> {skill.name}
              </button>
            </li>
          </ul>

          <p :if={@query != "" and @matches == []} class="text-xs text-base-content/50 mt-1">
            {gettext("No matching skills. Create them under Skills first.")}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
