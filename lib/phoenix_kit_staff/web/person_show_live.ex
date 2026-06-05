defmodule PhoenixKitStaff.Web.PersonShowLive do
  @moduledoc "Show a staff person's full profile and team memberships."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{L10n, Paths, Staff}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Person

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
        {:ok,
         assign(socket,
           page_title: Person.display_name(person),
           person: person,
           memberships: Staff.list_memberships_for_person(person.uuid)
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

  def handle_info(msg, socket) do
    Logger.debug("[Staff] PersonShowLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
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
          <.link navigate={Paths.edit_person(@person.uuid)} class="btn btn-ghost btn-sm">
            <.icon name="hero-pencil" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
          </.link>
        </:actions>
      </.admin_page_header>

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

      <%!-- Admin notes (visible only if present) --%>
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
    """
  end
end
