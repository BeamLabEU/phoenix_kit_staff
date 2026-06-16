defmodule PhoenixKitStaff.Web.PersonEmploymentComponent do
  @moduledoc """
  The **Employment** tab of a staff person's profile — a timeline of employment
  spans with add / edit / end / remove, persisted immediately via
  `PhoenixKitStaff.Employments`.

  The context denormalizes the current (open) span onto `Person` and broadcasts
  `:person_employment_changed`; the host `PersonShowLive` (subscribed to the
  person topic) reloads and re-renders this component, so the Overview header
  stays in sync. Activity is logged at this layer (actor from the passed-in
  `phoenix_kit_current_user`).

  v1 edits `job_title` in the primary language only; the span's `translations`
  column is preserved for a later per-language pass. The per-span team is a
  history snapshot (it does not change the person's `TeamMembership`).
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, Departments, Employments, L10n, Teams}
  alias PhoenixKitStaff.Schemas.{Employment, Person}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    person = socket.assigns.person

    {:ok,
     socket
     |> assign(:employments, Employments.list_for_person(person.uuid))
     |> assign_new(:editing_uuid, fn -> nil end)
     |> assign_new(:type_options, fn -> type_options() end)
     |> assign_new(:dept_options, fn -> dept_options() end)
     |> assign_new(:team_options, fn -> team_options() end)
     |> assign_new(:location_options, fn -> location_options() end)
     |> assign_new(:form, fn -> new_form() end)}
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("validate_employment", %{"employment" => attrs}, socket) do
    cs = %Employment{} |> Employment.changeset(attrs) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(cs, as: :employment))}
  end

  def handle_event("save_employment", %{"employment" => attrs}, socket) do
    person = socket.assigns.person

    result =
      case socket.assigns.editing_uuid do
        nil ->
          Employments.create(person.uuid, attrs)

        uuid ->
          case Employments.get(uuid) do
            nil -> {:error, :not_found}
            span -> Employments.update(span, attrs)
          end
      end

    case result do
      {:ok, span} ->
        log(socket, if(socket.assigns.editing_uuid, do: "updated", else: "added"), span)
        {:noreply, socket |> reset_form() |> reload()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs, as: :employment))}

      {:error, _other} ->
        {:noreply, reload(socket)}
    end
  end

  def handle_event("edit_employment", %{"uuid" => uuid}, socket) do
    case Employments.get(uuid) do
      nil ->
        {:noreply, reload(socket)}

      span ->
        {:noreply,
         assign(socket,
           editing_uuid: uuid,
           form: to_form(Employment.changeset(span, %{}), as: :employment)
         )}
    end
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, reset_form(socket)}

  def handle_event("end_employment", %{"uuid" => uuid}, socket) do
    with span when not is_nil(span) <- Employments.get(uuid),
         {:ok, ended} <- Employments.end_span(span, Date.utc_today()) do
      log(socket, "ended", ended)
      {:noreply, socket |> reset_form() |> reload()}
    else
      _ -> {:noreply, reload(socket)}
    end
  end

  def handle_event("remove_employment", %{"uuid" => uuid}, socket) do
    with span when not is_nil(span) <- Employments.get(uuid),
         {:ok, removed} <- Employments.delete(span) do
      log(socket, "removed", removed)
      {:noreply, socket |> reset_form() |> reload()}
    else
      _ -> {:noreply, reload(socket)}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp reload(socket),
    do: assign(socket, :employments, Employments.list_for_person(socket.assigns.person.uuid))

  defp reset_form(socket), do: assign(socket, editing_uuid: nil, form: new_form())

  defp new_form, do: to_form(Employment.changeset(%Employment{}, %{}), as: :employment)

  defp type_options do
    Enum.map(Person.employment_types(), &{Person.employment_type_label(&1), &1})
  end

  defp dept_options, do: Departments.list() |> Enum.map(&{&1.name, &1.uuid})
  defp team_options, do: Teams.list() |> Enum.map(&{&1.name, &1.uuid})

  # Soft dep on `phoenix_kit_locations` (same dispatch the person form used):
  # the optional module is resolved at runtime so a missing dep doesn't trip
  # `--warnings-as-errors`/dialyzer; returns `[]` (picker hidden) when absent.
  defp location_options do
    with true <- locations_module_enabled?(),
         {:module, mod} <- Code.ensure_loaded(PhoenixKitLocations.Locations) do
      try do
        mod.list_locations(status: "active") |> Enum.map(fn loc -> {loc.name, loc.uuid} end)
      rescue
        e in [Postgrex.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
          Logger.warning("[Staff] locations lookup failed: #{Exception.message(e)}")
          []
      end
    else
      _ -> []
    end
  end

  defp locations_module_enabled? do
    case Code.ensure_loaded(PhoenixKitLocations) do
      {:module, mod} -> function_exported?(mod, :enabled?, 0) and mod.enabled?()
      {:error, _} -> false
    end
  end

  defp log(socket, verb, span) do
    Activity.log("staff.person_employment_#{verb}",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "staff_person",
      resource_uuid: socket.assigns.person.uuid,
      metadata: %{"employment_uuid" => span.uuid, "employment_type" => span.employment_type}
    )
  end

  defp date_range(%Employment{} = e) do
    started = e.employment_start_date && L10n.format_date(e.employment_start_date)
    ended = e.employment_end_date && L10n.format_date(e.employment_end_date)

    cond do
      started && ended -> "#{started} – #{ended}"
      started -> "#{started} – #{gettext("present")}"
      ended -> "… – #{ended}"
      true -> gettext("no dates")
    end
  end

  defp title(%Employment{} = e, locale),
    do: blank_to(Employment.localized_job_title(e, locale), gettext("(untitled role)"))

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%!-- Add / edit span --%>
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-lg">
            {if @editing_uuid, do: gettext("Edit employment"), else: gettext("Add employment")}
          </h2>

          <.form
            for={@form}
            id={"employment-form-#{@id}"}
            phx-target={@myself}
            phx-change="validate_employment"
            phx-submit="save_employment"
            class="flex flex-col gap-3"
          >
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <.select
                field={@form[:employment_type]}
                label={gettext("Employment type")}
                options={@type_options}
                prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "—")}
              />
              <.input
                field={@form[:job_title]}
                label={gettext("Job title")}
                placeholder={gettext("e.g. Senior Engineer")}
              />
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <.select
                field={@form[:primary_department_uuid]}
                label={gettext("Department")}
                options={@dept_options}
                prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "None")}
              />
              <.select
                field={@form[:primary_team_uuid]}
                label={gettext("Team")}
                options={@team_options}
                prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "None")}
              />
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <.input field={@form[:employment_start_date]} label={gettext("Start date")} type="date" />
              <.input
                field={@form[:employment_end_date]}
                label={gettext("End date")}
                type="date"
              />
            </div>

            <.select
              :if={@location_options != []}
              field={@form[:work_location]}
              label={gettext("Work location")}
              options={@location_options}
              prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "—")}
            />

            <.textarea field={@form[:notes]} label={gettext("Notes")} />

            <p class="text-xs text-base-content/50">
              {gettext("Leave the end date empty for the current role. Starting a new current role ends the previous one.")}
            </p>

            <div class="flex justify-end gap-2">
              <button
                :if={@editing_uuid}
                type="button"
                phx-target={@myself}
                phx-click="cancel_edit"
                class="btn btn-ghost btn-sm"
              >
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}
              </button>
              <button
                type="submit"
                phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Saving…")}
                class="btn btn-primary btn-sm"
              >
                <%= if @editing_uuid,
                  do: Gettext.gettext(PhoenixKitWeb.Gettext, "Save"),
                  else: Gettext.gettext(PhoenixKitWeb.Gettext, "Add") %>
              </button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Timeline --%>
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-lg">
            {gettext("Employment history")} ({length(@employments)})
          </h2>

          <p :if={@employments == []} class="text-sm text-base-content/60 py-2">
            {gettext("No employment recorded yet. Add the first span above.")}
          </p>

          <div :if={@employments != []} class="flex flex-col gap-2">
            <div
              :for={e <- @employments}
              class="border border-base-300 rounded-box p-3 flex items-start gap-3"
            >
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="font-medium">{title(e, @locale)}</span>
                  <span :if={Employment.open?(e)} class="badge badge-success badge-sm">
                    {gettext("Current")}
                  </span>
                  <span :if={e.employment_type} class="badge badge-ghost badge-sm">
                    {Person.employment_type_label(e.employment_type)}
                  </span>
                </div>
                <div class="text-xs text-base-content/60 mt-0.5">
                  {date_range(e)}<span :if={e.department}> · {e.department.name}</span><span :if={
                    e.team
                  }> · {e.team.name}</span><span :if={e.work_location}> · {e.work_location}</span>
                </div>
                <p :if={e.notes} class="text-sm mt-1 whitespace-pre-line">{e.notes}</p>
              </div>

              <div class="flex items-center shrink-0">
                <button
                  type="button"
                  phx-target={@myself}
                  phx-click="edit_employment"
                  phx-value-uuid={e.uuid}
                  class="btn btn-ghost btn-xs btn-square"
                  aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                >
                  <.icon name="hero-pencil" class="w-4 h-4" />
                </button>
                <button
                  :if={Employment.open?(e)}
                  type="button"
                  phx-target={@myself}
                  phx-click="end_employment"
                  phx-value-uuid={e.uuid}
                  class="btn btn-ghost btn-xs btn-square"
                  aria-label={gettext("End now")}
                  title={gettext("End this role today")}
                >
                  <.icon name="hero-flag" class="w-4 h-4" />
                </button>
                <button
                  type="button"
                  phx-target={@myself}
                  phx-click="remove_employment"
                  phx-value-uuid={e.uuid}
                  data-confirm={gettext("Remove this employment record?")}
                  class="btn btn-ghost btn-xs btn-square text-error"
                  aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
