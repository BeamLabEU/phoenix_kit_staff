defmodule PhoenixKitStaff.Web.PersonShowLive do
  @moduledoc "Show a staff person's full profile and team memberships."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  # Comments is a hard dep (the Comments tab embeds CommentsComponent). This
  # attaches a :handle_info lifecycle hook that forwards the composer's
  # {:leaf_changed, …} message into CommentsComponent.forward_leaf_event/2
  # (halts only :leaf_changed) — without it "Post comment" silently no-ops.
  use PhoenixKitComments.Embed

  require Logger

  alias PhoenixKitStaff.{Activity, L10n, Paths, Skills, Staff}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Person, Skill}
  alias PhoenixKitStaff.Web.Helpers

  import PhoenixKitStaff.Web.Components.TabsStrip

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Subscribe BEFORE the DB read so a broadcast between fetch and
    # subscribe doesn't get dropped. URL `id` is the UUID; same topic.
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_person(id))

    case Staff.get_person(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Staff not found."))
         |> push_navigate(to: Paths.people())}

      person ->
        # The Comments tab shows only when the comments module's admin
        # toggle is on (`enabled?()`). The module itself is a hard dep, so
        # it's always loadable — only the runtime feature flag gates the tab.
        {:ok,
         socket
         |> assign(
           page_title: Person.display_name(person),
           person: person,
           memberships: Staff.list_memberships_for_person(person.uuid),
           active_tab: "overview",
           comments_enabled: comments_enabled?()
         )
         |> load_skills()}
    end
  end

  # The person's skill assignments (read-only here — assignment is staged
  # on the edit form and persisted on Save).
  defp load_skills(socket) do
    assign(socket, person_skills: Skills.list_for_person(socket.assigns.person.uuid))
  end

  # Localized, comma-joined names of an assignment's selected level options
  # across all selectors (stray ids — e.g. an option deleted from the skill —
  # resolve to nil and are dropped). Stored ids are already in skill order.
  defp level_names(%{skill: %Skill{} = skill, proficiency_levels: ids}, locale)
       when is_list(ids) do
    ids
    |> Enum.map(&Skill.localized_option_name(skill, &1, locale))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp level_names(_ps, _locale), do: ""

  @impl true
  def handle_info({:staff, :person_deleted, _}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This staff member was deleted."))
     |> push_navigate(to: Paths.people())}
  end

  def handle_info({:staff, _event, _payload}, socket) do
    case Staff.get_person(socket.assigns.person.uuid) do
      nil ->
        {:noreply, push_navigate(socket, to: Paths.people())}

      person ->
        {:noreply,
         socket
         |> assign(
           person: person,
           memberships: Staff.list_memberships_for_person(person.uuid)
         )
         |> load_skills()}
    end
  end

  # Emitted by the embedded comments LiveComponent on create/delete. We
  # don't surface a comment count on the profile, so this is a no-op —
  # declared explicitly to keep it out of the unexpected-message log.
  def handle_info({:comments_updated, _info}, socket), do: {:noreply, socket}

  # Note: the composer's {:leaf_changed, …} message is handled by the
  # `use PhoenixKitComments.Embed` lifecycle hook (it halts before reaching
  # handle_info), so there's no explicit clause for it here.
  def handle_info(msg, socket) do
    Logger.debug("[Staff] PersonShowLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    # Clamp to a currently-available tab so a stale/crafted value (e.g.
    # "comments" when the module is gone) can't land on a blank panel.
    tab = if tab in valid_tabs(socket.assigns.comments_enabled), do: tab, else: "overview"
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("trash", _params, socket) do
    person = socket.assigns.person

    case Staff.trash_person(person) do
      {:ok, updated} ->
        Activity.log("staff.person_trashed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid,
          metadata: %{}
        )

        {:noreply,
         socket |> assign(person: updated) |> put_flash(:info, gettext("Staff moved to trash."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not move staff to trash."))}
    end
  end

  def handle_event("restore", _params, socket) do
    person = socket.assigns.person

    case Staff.restore_person(person) do
      {:ok, updated} ->
        Activity.log("staff.person_restored",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid,
          metadata: %{}
        )

        {:noreply,
         socket |> assign(person: updated) |> put_flash(:info, gettext("Staff restored."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not restore staff."))}
    end
  end

  def handle_event("permanent_delete", _params, socket) do
    person = socket.assigns.person

    case Staff.delete_person(person) do
      {:ok, _} ->
        Activity.log("staff.person_deleted",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid,
          metadata: %{}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Staff permanently deleted."))
         |> push_navigate(to: Paths.people())}

      {:error, :referenced_by_external} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This staff is still referenced elsewhere and couldn't be deleted.")
         )}

      {:error, reason} ->
        Helpers.log_operation_error("staff.person_deleted", socket,
          reason: reason,
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid
        )

        {:noreply, put_flash(socket, :error, gettext("Could not delete staff."))}
    end
  end

  # The Comments tab is gated on the comments module's admin toggle.
  # `phoenix_kit_comments` is a hard dep, so the call is direct — rescued
  # only so a missing settings table during boot/discovery never crashes.
  defp comments_enabled? do
    PhoenixKitComments.enabled?()
  rescue
    _ -> false
  end

  defp has_any?(m, fields) do
    Enum.any?(fields, fn f -> present?(Map.get(m, f)) end)
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp format_date(nil), do: "—"
  defp format_date(d), do: L10n.format_date(d)

  defp format_birthday(nil), do: nil

  defp format_birthday(dob) do
    today = Date.utc_today()

    age =
      today.year - dob.year -
        if({today.month, today.day} < {dob.month, dob.day}, do: 1, else: 0)

    next_bday = days_until_birthday(dob, today)

    upcoming =
      cond do
        next_bday == 0 -> " · " <> gettext("🎂 today!")
        next_bday <= 30 -> " · " <> ngettext("🎂 in 1 day", "🎂 in %{count} days", next_bday)
        true -> ""
      end

    gettext("%{date} · age %{age}", date: L10n.format_date(dob), age: age) <>
      upcoming
  end

  defp days_until_birthday(dob, today) do
    this_year =
      case Date.new(today.year, dob.month, dob.day) do
        {:ok, d} -> d
        {:error, _} -> Date.new!(today.year, dob.month, min(dob.day, 28))
      end

    if Date.compare(this_year, today) == :lt do
      next_year = Date.new!(today.year + 1, dob.month, min(dob.day, 28))
      Date.diff(next_year, today)
    else
      Date.diff(this_year, today)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <.admin_page_header
        title={Person.display_name(@person)}
        subtitle={@person.job_title}
      >
        <:actions>
          <%= if Person.trashed?(@person) do %>
            <button
              type="button"
              phx-click="restore"
              phx-disable-with={gettext("Restoring…")}
              class="btn btn-success btn-sm"
            >
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Restore")}
            </button>
            <button
              type="button"
              phx-click="permanent_delete"
              phx-disable-with={gettext("Deleting…")}
              data-confirm={gettext("Permanently delete this staff? This cannot be undone and will clear their project-assignment links.")}
              class="btn btn-error btn-outline btn-sm"
            >
              <.icon name="hero-x-circle" class="w-4 h-4" /> {gettext("Delete permanently")}
            </button>
          <% else %>
            <.link navigate={Paths.edit_person(@person.uuid)} class="btn btn-ghost btn-sm">
              <.icon name="hero-pencil" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
            </.link>
            <button
              type="button"
              phx-click="trash"
              phx-disable-with={gettext("Moving…")}
              data-confirm={gettext("Move this staff to the trash? The user account stays; restore anytime from the Trash filter.")}
              class="btn btn-ghost btn-sm text-error"
            >
              <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Move to trash")}
            </button>
          <% end %>
        </:actions>
      </.admin_page_header>

      <div
        :if={Person.trashed?(@person)}
        class="alert alert-warning"
        role="alert"
      >
        <.icon name="hero-trash" class="w-5 h-5" />
        <span>{gettext("This staff is in the trash. Restore to bring them back to the active roster.")}</span>
      </div>

      <.tabs_strip event="switch_tab" active={@active_tab} tabs={tab_list(@comments_enabled)} />

      <%!-- Overview tab — the full profile --%>
      <div :if={@active_tab == "overview"} class="flex flex-col gap-4">
        <%!-- Hero profile card --%>
        <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex flex-wrap items-center gap-2 text-xs text-base-content/60">
            <span class={"badge badge-sm #{if @person.status == "active", do: "badge-success", else: "badge-ghost"}"}>
              {Person.status_label(@person.status)}
            </span>
            <%= if @person.employment_type do %>
              <span class="badge badge-sm badge-ghost">
                {Person.employment_type_label(@person.employment_type)}
              </span>
            <% end %>
            <%= if @person.primary_department do %>
              <.link navigate={Paths.department(@person.primary_department.uuid)} class="link link-hover">
                <.icon name="hero-building-office-2" class="w-3 h-3 inline" />
                {@person.primary_department.name}
              </.link>
            <% end %>
            <%= if @person.work_location do %>
              <span>
                <.icon name="hero-map-pin" class="w-3 h-3 inline" />
                {@person.work_location}
              </span>
            <% end %>
          </div>

          <%!-- Bio --%>
          <%= if @person.bio do %>
            <div class="mt-4 text-sm leading-relaxed whitespace-pre-line">{@person.bio}</div>
          <% end %>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <%!-- Employment details --%>
        <%= if has_any?(@person, [:employment_start_date, :employment_end_date, :employment_type, :work_location]) do %>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-briefcase" class="w-5 h-5" /> {gettext("Employment")}
              </h2>
              <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm mt-2">
                <%= if @person.employment_type do %>
                  <dt class="text-base-content/60">{Gettext.gettext(PhoenixKitWeb.Gettext, "Type")}</dt>
                  <dd>{Person.employment_type_label(@person.employment_type)}</dd>
                <% end %>
                <%= if @person.employment_start_date do %>
                  <dt class="text-base-content/60">{gettext("Started")}</dt>
                  <dd>{format_date(@person.employment_start_date)}</dd>
                <% end %>
                <%= if @person.employment_end_date do %>
                  <dt class="text-base-content/60">{gettext("Ended")}</dt>
                  <dd>{format_date(@person.employment_end_date)}</dd>
                <% end %>
                <%= if @person.work_location do %>
                  <dt class="text-base-content/60">{gettext("Location")}</dt>
                  <dd>{@person.work_location}</dd>
                <% end %>
              </dl>
            </div>
          </div>
        <% end %>

        <%!-- Contact --%>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">
              <.icon name="hero-phone" class="w-5 h-5" /> {gettext("Contact")}
            </h2>
            <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm mt-2">
              <dt class="text-base-content/60">{gettext("Work email")}</dt>
              <dd class="font-mono text-xs">{@person.user && @person.user.email || "—"}</dd>
              <%= if @person.personal_email do %>
                <dt class="text-base-content/60">{gettext("Personal email")}</dt>
                <dd class="font-mono text-xs">
                  <a href={"mailto:#{@person.personal_email}"} class="link link-hover">
                    {@person.personal_email}
                  </a>
                </dd>
              <% end %>
              <%= if @person.work_phone do %>
                <dt class="text-base-content/60">{gettext("Work phone")}</dt>
                <dd><a href={"tel:#{@person.work_phone}"} class="link link-hover">{@person.work_phone}</a></dd>
              <% end %>
              <%= if @person.personal_phone do %>
                <dt class="text-base-content/60">{gettext("Personal phone")}</dt>
                <dd><a href={"tel:#{@person.personal_phone}"} class="link link-hover">{@person.personal_phone}</a></dd>
              <% end %>
            </dl>
          </div>
        </div>

        <%!-- Personal --%>
        <%= if @person.date_of_birth do %>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-cake" class="w-5 h-5" /> {gettext("Personal")}
              </h2>
              <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm mt-2">
                <dt class="text-base-content/60">{gettext("Birthday")}</dt>
                <dd>{format_birthday(@person.date_of_birth)}</dd>
              </dl>
            </div>
          </div>
        <% end %>

        <%!-- Emergency contact --%>
        <%= if has_any?(@person, [:emergency_contact_name, :emergency_contact_phone, :emergency_contact_relationship]) do %>
          <div class="card bg-base-100 shadow">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-shield-exclamation" class="w-5 h-5 text-warning" /> {gettext("Emergency contact")}
              </h2>
              <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm mt-2">
                <%= if @person.emergency_contact_name do %>
                  <dt class="text-base-content/60">{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</dt>
                  <dd>{@person.emergency_contact_name}</dd>
                <% end %>
                <%= if @person.emergency_contact_relationship do %>
                  <dt class="text-base-content/60">{gettext("Relationship")}</dt>
                  <dd>{@person.emergency_contact_relationship}</dd>
                <% end %>
                <%= if @person.emergency_contact_phone do %>
                  <dt class="text-base-content/60">{gettext("Phone")}</dt>
                  <dd>
                    <a href={"tel:#{@person.emergency_contact_phone}"} class="link link-hover">
                      {@person.emergency_contact_phone}
                    </a>
                  </dd>
                <% end %>
              </dl>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Teams --%>
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-lg">
            <.icon name="hero-user-group" class="w-5 h-5" /> {gettext("Teams")} ({length(@memberships)})
          </h2>
          <%= if @memberships == [] do %>
            <.empty_state
              icon="hero-user-group"
              title={gettext("Not on any teams yet.")}
              class="py-6"
            />
          <% else %>
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Team")}</th>
                  <th>{gettext("Department")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={tm <- @memberships}>
                  <td>
                    <.link navigate={Paths.team(tm.team.uuid)} class="link link-hover font-medium">
                      {tm.team.name}
                    </.link>
                  </td>
                  <td>{tm.team.department.name}</td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>

      <%!-- Skills — read-only display; assignment is managed on the edit page. --%>
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <h2 class="card-title text-lg">
              <.icon name="hero-academic-cap" class="w-5 h-5" /> {gettext("Skills")} ({length(@person_skills)})
            </h2>
            <.link navigate={Paths.edit_person(@person.uuid)} class="btn btn-ghost btn-xs">
              <.icon name="hero-pencil" class="w-3.5 h-3.5" /> {gettext("Manage")}
            </.link>
          </div>

          <%= if @person_skills == [] do %>
            <.empty_state icon="hero-academic-cap" title={gettext("No skills assigned yet.")} class="py-6">
              <:cta>
                <.link navigate={Paths.edit_person(@person.uuid)} class="link link-primary text-sm">
                  {gettext("Add skills")}
                </.link>
              </:cta>
            </.empty_state>
          <% else %>
            <div class="flex flex-wrap gap-2 mt-1">
              <.link
                :for={ps <- @person_skills}
                navigate={Paths.skill(ps.skill.uuid)}
                class="badge badge-lg badge-outline gap-1 hover:badge-primary"
              >
                {ps.skill.name}
                <span :if={level_names(ps, assigns[:current_locale]) != ""} class="opacity-60">
                  · {level_names(ps, assigns[:current_locale])}
                </span>
              </.link>
            </div>
          <% end %>
        </div>
      </div>

        <%!-- Admin notes — legacy, read-only (the editable field moved
             to the Comments tab). Self-hides when the person has none. --%>
        <%= if @person.notes do %>
          <div class="card bg-warning/10 border border-warning/30 shadow-sm">
            <div class="card-body">
              <h2 class="card-title text-base text-warning-content">
                <.icon name="hero-lock-closed" class="w-4 h-4" /> {gettext("Admin notes")}
              </h2>
              <div class="text-sm whitespace-pre-line">{@person.notes}</div>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Comments tab — embedded thread. The tab only renders when the
           comments admin toggle is on (see `comments_enabled?`). --%>
      <div :if={@active_tab == "comments"}>
        <.live_component
          module={PhoenixKitComments.Web.CommentsComponent}
          id={"staff-person-comments-#{@person.uuid}"}
          resource_type="staff_person"
          resource_uuid={@person.uuid}
          current_user={@phoenix_kit_current_user}
        />
      </div>
    </div>
    """
  end

  # Tab set for the profile: Overview always; Comments only when the
  # comments module's admin toggle is enabled.
  defp valid_tabs(comments_enabled?) do
    comments_enabled? |> tab_list() |> Enum.map(fn {value, _label, _icon} -> value end)
  end

  defp tab_list(comments_enabled?) do
    overview = {"overview", gettext("Overview"), "hero-identification"}

    if comments_enabled? do
      [overview, {"comments", gettext("Comments"), "hero-chat-bubble-left-right"}]
    else
      [overview]
    end
  end
end
