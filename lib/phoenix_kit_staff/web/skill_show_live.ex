defmodule PhoenixKitStaff.Web.SkillShowLive do
  @moduledoc "Show a skill and manage which people have it (with proficiency level)."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, Paths, Skills}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Person, PersonSkill}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_skill(id))

    case Skills.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Skill not found."))
         |> push_navigate(to: Paths.skills())}

      skill ->
        {:ok, socket |> assign(page_title: skill.name, skill: skill) |> load_assignments()}
    end
  end

  @impl true
  def handle_info({:staff, :skill_deleted, _}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This skill was deleted."))
     |> push_navigate(to: Paths.skills())}
  end

  def handle_info({:staff, _event, _payload}, socket) do
    case Skills.get(socket.assigns.skill.uuid) do
      nil -> {:noreply, push_navigate(socket, to: Paths.skills())}
      skill -> {:noreply, socket |> assign(skill: skill) |> load_assignments()}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[Staff] SkillShowLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_assignments(socket) do
    skill_uuid = socket.assigns.skill.uuid

    assign(socket,
      assignments: Skills.list_people_for_skill(skill_uuid),
      available_people: Skills.people_without_skill(skill_uuid),
      add_form: to_form(%{"staff_person_uuid" => "", "proficiency_level" => ""}, as: :assign)
    )
  end

  @impl true
  def handle_event("add_person", %{"assign" => %{"staff_person_uuid" => ""}}, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick someone first."))}
  end

  def handle_event(
        "add_person",
        %{"assign" => %{"staff_person_uuid" => person_uuid} = params},
        socket
      ) do
    level = Map.get(params, "proficiency_level")

    case Skills.assign_skill(person_uuid, socket.assigns.skill.uuid, level) do
      {:ok, ps} ->
        Activity.log("staff.person_skill_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "skill",
          resource_uuid: socket.assigns.skill.uuid,
          target_uuid: person_uuid,
          metadata: %{"person_skill_uuid" => ps.uuid, "proficiency_level" => ps.proficiency_level}
        )

        {:noreply, socket |> put_flash(:info, gettext("Staff added.")) |> load_assignments()}

      {:error, %Ecto.Changeset{errors: errors}} when is_list(errors) ->
        if Keyword.has_key?(errors, :staff_person_uuid) do
          {:noreply,
           socket
           |> load_assignments()
           |> put_flash(:info, gettext("That person already has this skill."))}
        else
          {:noreply, put_flash(socket, :error, gettext("Could not add staff."))}
        end
    end
  end

  def handle_event("change_level", %{"uuid" => ps_uuid, "proficiency_level" => level}, socket) do
    case Enum.find(socket.assigns.assignments, &(&1.uuid == ps_uuid)) do
      %PersonSkill{} = ps ->
        case Skills.update_assignment_level(ps, level) do
          {:ok, _} ->
            Activity.log("staff.person_skill_updated",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "skill",
              resource_uuid: socket.assigns.skill.uuid,
              target_uuid: ps.staff_person_uuid,
              metadata: %{
                "person_skill_uuid" => ps.uuid,
                "proficiency_level" => blank_to_nil(level)
              }
            )

            {:noreply, load_assignments(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update level."))}
        end

      nil ->
        {:noreply, load_assignments(socket)}
    end
  end

  def handle_event("remove_person", %{"uuid" => ps_uuid}, socket) do
    case Enum.find(socket.assigns.assignments, &(&1.uuid == ps_uuid)) do
      %PersonSkill{} = ps ->
        case Skills.unassign_skill(ps) do
          {:ok, _} ->
            Activity.log("staff.person_skill_removed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "skill",
              resource_uuid: socket.assigns.skill.uuid,
              target_uuid: ps.staff_person_uuid,
              metadata: %{}
            )

            {:noreply, load_assignments(socket) |> put_flash(:info, gettext("Staff removed."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not remove staff."))}
        end

      nil ->
        {:noreply, load_assignments(socket)}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <.admin_page_header>
        <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">{@skill.name}</h1>
        <p :if={@skill.description} class="text-sm sm:text-base text-base-content/60 mt-0.5">
          {@skill.description}
        </p>
        <:actions>
          <.link navigate={Paths.edit_skill(@skill.uuid)} class="btn btn-ghost btn-sm">
            <.icon name="hero-pencil" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
          </.link>
        </:actions>
      </.admin_page_header>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-lg">{gettext("Add staff")}</h2>
          <%= if @available_people == [] do %>
            <p class="text-sm text-base-content/60">
              {gettext("Everyone already has this skill (or there are no staff yet —")} <.link navigate={Paths.new_person()} class="link link-primary">{gettext("create one")}</.link>).
            </p>
          <% else %>
            <.form
              for={@add_form}
              id="skill-add-person-form"
              phx-submit="add_person"
              class="flex flex-wrap gap-2 items-end"
            >
              <.select
                field={@add_form[:staff_person_uuid]}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")}
                options={Enum.map(@available_people, &{person_label(&1), &1.uuid})}
                prompt={gettext("Select staff")}
              />
              <.select
                field={@add_form[:proficiency_level]}
                label={gettext("Level")}
                options={Enum.map(PersonSkill.proficiency_levels(), &{PersonSkill.proficiency_label(&1), &1})}
                prompt={PersonSkill.proficiency_label(nil)}
              />
              <button type="submit" phx-disable-with={gettext("Adding…")} class="btn btn-primary btn-sm">
                <.icon name="hero-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Add")}
              </button>
            </.form>
          <% end %>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-lg">{Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")} ({length(@assignments)})</h2>
          <%= if @assignments == [] do %>
            <.empty_state
              icon="hero-identification"
              title={gettext("No one has this skill yet.")}
              class="py-6"
            />
          <% else %>
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")}</th>
                  <th>{gettext("Level")}</th>
                  <th class="text-right w-px whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={a <- @assignments}>
                  <td>
                    <.link navigate={Paths.person(a.staff_person.uuid)} class="link link-hover">
                      {person_label(a.staff_person)}
                    </.link>
                  </td>
                  <td>
                    <form phx-change="change_level">
                      <input type="hidden" name="uuid" value={a.uuid} />
                      <select name="proficiency_level" class="select select-sm select-bordered">
                        <option value="" selected={is_nil(a.proficiency_level)}>
                          {PersonSkill.proficiency_label(nil)}
                        </option>
                        <option
                          :for={lvl <- PersonSkill.proficiency_levels()}
                          value={lvl}
                          selected={a.proficiency_level == lvl}
                        >
                          {PersonSkill.proficiency_label(lvl)}
                        </option>
                      </select>
                    </form>
                  </td>
                  <td class="text-right w-px whitespace-nowrap">
                    <.table_row_menu id={"assignment-menu-#{a.uuid}"}>
                      <.table_row_menu_link
                        navigate={Paths.person(a.staff_person.uuid)}
                        icon="hero-eye"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="remove_person"
                        phx-value-uuid={a.uuid}
                        phx-disable-with={gettext("Removing…")}
                        data-confirm={gettext("Remove this skill from the person?")}
                        icon="hero-x-mark"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
                        variant="error"
                      />
                    </.table_row_menu>
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

  defp person_label(%Person{} = person), do: Person.display_name(person)
  defp person_label(_), do: "—"
end
