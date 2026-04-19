defmodule PhoenixKitStaff.Web.DepartmentFormLive do
  @moduledoc "Create or edit a department."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitStaff.{Activity, Departments, Paths}

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    dept = %PhoenixKitStaff.Schemas.Department{}

    socket
    |> assign(page_title: gettext("New department"), dept: dept, live_action: :new)
    |> assign_form(Departments.change(dept))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Departments.get(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Department not found."))
        |> push_navigate(to: Paths.departments())

      dept ->
        socket
        |> assign(
          page_title: gettext("Edit %{name}", name: dept.name),
          dept: dept,
          live_action: :edit
        )
        |> assign_form(Departments.change(dept))
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset))

  @impl true
  def handle_event("validate", %{"department" => attrs}, socket) do
    cs = socket.assigns.dept |> Departments.change(attrs) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, cs)}
  end

  def handle_event("save", %{"department" => attrs}, socket) do
    save(socket, socket.assigns.live_action, attrs)
  end

  defp save(socket, :new, attrs) do
    case Departments.create(attrs) do
      {:ok, dept} ->
        Activity.log("staff.department_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "department",
          resource_uuid: dept.uuid,
          metadata: %{"name" => dept.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Department created."))
         |> push_navigate(to: Paths.department(dept.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Departments.update(socket.assigns.dept, attrs) do
      {:ok, dept} ->
        Activity.log("staff.department_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "department",
          resource_uuid: dept.uuid,
          metadata: %{"name" => dept.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Department updated."))
         |> push_navigate(to: Paths.department(dept.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-xl px-4 py-6 gap-4">
      <div>
        <.link navigate={Paths.departments()} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Departments")}
        </.link>
        <h1 class="text-2xl font-bold mt-1">{@page_title}</h1>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <.form for={@form} id="department-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-3">
            <.input field={@form[:name]} label={gettext("Name")} required />
            <.textarea field={@form[:description]} label={gettext("Description")} />
            <div class="flex justify-end gap-2 mt-2">
              <.link navigate={Paths.departments()} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
              <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
