defmodule PhoenixKitStaff.Web.TeamFormLive do
  @moduledoc "Create or edit a team."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitStaff.{Activity, Departments, Paths, Teams}

  @impl true
  def mount(params, _session, socket) do
    departments = Departments.list()

    socket =
      socket
      |> assign(dept_options: Enum.map(departments, &{&1.name, &1.uuid}))
      |> apply_action(socket.assigns.live_action, params)

    {:ok, socket}
  end

  defp apply_action(socket, :new, _params) do
    team = %PhoenixKitStaff.Schemas.Team{}

    socket
    |> assign(page_title: gettext("New team"), team: team, live_action: :new)
    |> assign_form(Teams.change(team))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Teams.get(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Team not found."))
        |> push_navigate(to: Paths.teams())

      team ->
        socket
        |> assign(
          page_title: gettext("Edit %{name}", name: team.name),
          team: team,
          live_action: :edit
        )
        |> assign_form(Teams.change(team))
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("validate", %{"team" => attrs}, socket) do
    cs = socket.assigns.team |> Teams.change(attrs) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, cs)}
  end

  def handle_event("save", %{"team" => attrs}, socket) do
    save(socket, socket.assigns.live_action, attrs)
  end

  defp save(socket, :new, attrs) do
    case Teams.create(attrs) do
      {:ok, team} ->
        Activity.log("staff.team_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "team",
          resource_uuid: team.uuid,
          metadata: %{"name" => team.name, "department_uuid" => team.department_uuid}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Team created."))
         |> push_navigate(to: Paths.team(team.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Teams.update(socket.assigns.team, attrs) do
      {:ok, team} ->
        Activity.log("staff.team_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "team",
          resource_uuid: team.uuid,
          metadata: %{"name" => team.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Team updated."))
         |> push_navigate(to: Paths.team(team.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-xl px-4 py-6 gap-4">
      <div>
        <.link navigate={Paths.teams()} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Teams")}
        </.link>
        <h1 class="text-2xl font-bold mt-1">{@page_title}</h1>
      </div>

      <%= if @dept_options == [] do %>
        <div class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>
            {gettext("You need at least one department first.")}
            <.link navigate={Paths.new_department()} class="link">{gettext("Create one")}</.link>.
          </span>
        </div>
      <% else %>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <.form for={@form} id="team-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-3">
              <.select
                field={@form[:department_uuid]}
                label={gettext("Department")}
                options={@dept_options}
                prompt={gettext("Select department")}
                required
              />
              <.input field={@form[:name]} label={gettext("Name")} required />
              <.textarea field={@form[:description]} label={gettext("Description")} />
              <div class="flex justify-end gap-2 mt-2">
                <.link navigate={Paths.teams()} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
                <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                  <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
