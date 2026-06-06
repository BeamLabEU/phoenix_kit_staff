defmodule PhoenixKitStaff.Web.PersonShowLive do
  @moduledoc "Show a staff person's full profile and team memberships."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, L10n, Paths, Staff}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Person
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
        # Resolve the component once and derive tab availability from
        # BOTH the setting and the module actually being loadable, so a
        # skewed install (setting on, component missing) never shows a
        # blank Comments tab.
        comments_module = comments_module()
        comments_enabled = comments_module != nil and comments_enabled?()

        {:ok,
         assign(socket,
           page_title: Person.display_name(person),
           person: person,
           memberships: Staff.list_memberships_for_person(person.uuid),
           active_tab: "overview",
           comments_enabled: comments_enabled,
           comments_module: comments_module
         )}
    end
  end

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
         assign(socket,
           person: person,
           memberships: Staff.list_memberships_for_person(person.uuid)
         )}
    end
  end

  # Emitted by the embedded comments LiveComponent on create/delete. We
  # don't surface a comment count on the profile, so this is a no-op —
  # declared explicitly to keep it out of the unexpected-message log.
  def handle_info({:comments_updated, _info}, socket), do: {:noreply, socket}

  # The comments composer's rich-text (Leaf) editor doesn't bubble its
  # content through the form params, so it sends `{:leaf_changed, ...}`
  # to this host LV; we must forward it to the CommentsComponent (via
  # `forward_leaf_event/2`) so the component's `new_comment` assign stays
  # current and "Post comment" actually has content to submit. Soft-dep:
  # resolved at runtime so staff still builds without phoenix_kit_comments.
  def handle_info({:leaf_changed, _} = msg, socket) do
    case comments_module() do
      nil ->
        {:noreply, socket}

      mod ->
        case mod.forward_leaf_event(msg, socket) do
          {:noreply, socket} -> {:noreply, socket}
          _ -> {:noreply, socket}
        end
    end
  end

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

  # ── Optional comments soft-dep ─────────────────────────────────────
  # `phoenix_kit_comments` is not a staff dependency. Resolve it through
  # `Code.ensure_loaded/1` (same idiom as the locations soft-dep in
  # person_form_live) so the optional module is never named as a call
  # target at compile time — no `--warnings-as-errors` / dialyzer noise
  # when it isn't installed.

  defp comments_enabled? do
    case Code.ensure_loaded(PhoenixKitComments) do
      {:module, mod} -> function_exported?(mod, :enabled?, 0) and mod.enabled?()
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  defp comments_module do
    case Code.ensure_loaded(PhoenixKitComments.Web.CommentsComponent) do
      {:module, mod} -> mod
      {:error, _} -> nil
    end
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

          <%!-- Skills --%>
          <%= if @person.skills do %>
            <div class="flex flex-wrap gap-1 mt-3">
              <span
                :for={skill <- Person.skill_list(@person.skills)}
                class="badge badge-outline badge-sm"
              >
                {skill}
              </span>
            </div>
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

      <%!-- Comments tab — embedded thread, only when the optional
           phoenix_kit_comments module is installed + enabled. --%>
      <div :if={@active_tab == "comments"}>
        <.live_component
          :if={@comments_module}
          module={@comments_module}
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
  # optional comments module is installed + enabled.
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
