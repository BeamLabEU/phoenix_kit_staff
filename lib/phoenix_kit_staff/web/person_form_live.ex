defmodule PhoenixKitStaff.Web.PersonFormLive do
  @moduledoc "Create or edit a staff person."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKitStaff.{Activity, Departments, Paths, Staff, Teams}
  alias PhoenixKitStaff.Schemas.Person

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    person = %Person{}

    socket
    |> assign(
      page_title: gettext("New staff"),
      person: person,
      live_action: :new,
      email: "",
      email_status: :blank,
      eligible_users: Staff.eligible_users(),
      email_editable?: true,
      dept_options: dept_options(),
      team_options: [],
      selected_team_uuid: nil
    )
    |> assign_form(Staff.change_person(person))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Staff.get_person(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Staff not found."))
        |> push_navigate(to: Paths.people())

      person ->
        socket
        |> assign(
          page_title: gettext("Edit staff"),
          person: person,
          live_action: :edit,
          email: (person.user && person.user.email) || "",
          email_status: :blank,
          eligible_users: [],
          email_editable?: placeholder_user?(person.user),
          dept_options: dept_options(),
          team_options: team_options_for(person.primary_department_uuid),
          selected_team_uuid: nil
        )
        |> assign_form(Staff.change_person(person))
    end
  end

  defp placeholder_user?(nil), do: false

  defp placeholder_user?(user) do
    is_nil(user.confirmed_at) and
      Map.get(user.custom_fields || %{}, "source") == "staff_placeholder"
  end

  defp dept_options do
    Departments.list() |> Enum.map(&{&1.name, &1.uuid})
  end

  defp team_options_for(nil), do: []

  defp team_options_for(dept_uuid) do
    Teams.list(department_uuid: dept_uuid) |> Enum.map(&{&1.name, &1.uuid})
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("validate", %{"person" => attrs} = params, socket) do
    cs = socket.assigns.person |> Staff.change_person(attrs) |> Map.put(:action, :validate)
    dept_uuid = attrs["primary_department_uuid"]
    team_uuid = params["team_uuid"]
    email = Map.get(params, "email", socket.assigns.email) |> String.trim()

    {:noreply,
     socket
     |> assign_form(cs)
     |> assign(
       email: email,
       email_status: email_status(email, socket.assigns.eligible_users),
       team_options: team_options_for(blank_to_nil(dept_uuid)),
       selected_team_uuid: blank_to_nil(team_uuid)
     )}
  end

  def handle_event("save", %{"person" => attrs} = params, socket) do
    email = Map.get(params, "email", "") |> String.trim()
    team_uuid = blank_to_nil(params["team_uuid"])
    save(socket, socket.assigns.live_action, attrs, email, team_uuid)
  end

  defp email_status("", _), do: :blank

  defp email_status(email, _eligible) do
    cond do
      not Staff.valid_email?(email) ->
        :invalid

      existing_user = Auth.get_user_by_email(email) ->
        if has_staff_profile?(existing_user.uuid),
          do: :has_profile,
          else: {:existing, existing_user}

      true ->
        :new
    end
  end

  defp has_staff_profile?(user_uuid) do
    case PhoenixKit.RepoHelper.repo().get_by(Person, user_uuid: user_uuid) do
      nil -> false
      _ -> true
    end
  end

  defp save(socket, :new, attrs, email, team_uuid) do
    case Staff.create_person_with_user(email, attrs) do
      {:ok, person, status_tag} ->
        team_result = maybe_add_to_team(socket, person, team_uuid)

        Activity.log("staff.person_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid,
          metadata: %{
            "status" => person.status,
            "user_status" => to_string(status_tag)
          }
        )

        {kind, flash} = create_flash(status_tag, team_result, email)

        {:noreply,
         socket
         |> put_flash(kind, flash)
         |> push_navigate(to: Paths.person(person.uuid))}

      {:error, :blank_email} ->
        {:noreply, put_flash(socket, :error, gettext("Email is required."))}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp save(socket, :edit, attrs, email, team_uuid) do
    person = socket.assigns.person
    current_email = person.user && person.user.email
    new_email = String.trim(email)

    email_changed? =
      socket.assigns.email_editable? and new_email != "" and new_email != current_email

    rename_result =
      if email_changed? do
        Staff.rename_placeholder_email(person.user, new_email)
      else
        :ok
      end

    case rename_result do
      :ok ->
        do_update_person(socket, attrs, team_uuid)

      {:ok, _} ->
        do_update_person(socket, attrs, team_uuid)

      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, %Ecto.Changeset{} = cs} ->
        errors = Enum.map_join(cs.errors, ", ", fn {k, {m, _}} -> "#{k}: #{m}" end)

        {:noreply,
         put_flash(socket, :error, gettext("Could not rename email — %{errors}", errors: errors))}
    end
  end

  defp do_update_person(socket, attrs, team_uuid) do
    case Staff.update_person(socket.assigns.person, attrs) do
      {:ok, person} ->
        team_result = maybe_add_to_team(socket, person, team_uuid)

        Activity.log("staff.person_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid,
          metadata: %{}
        )

        {kind, flash} = update_flash(team_result)

        {:noreply,
         socket
         |> put_flash(kind, flash)
         |> push_navigate(to: Paths.person(person.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp maybe_add_to_team(_socket, _person, nil), do: :ok

  defp maybe_add_to_team(socket, person, team_uuid) do
    case Staff.add_team_person(team_uuid, person.uuid) do
      {:ok, tm} ->
        Activity.log("staff.team_person_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "team",
          resource_uuid: team_uuid,
          target_uuid: person.uuid,
          metadata: %{"team_membership_uuid" => tm.uuid}
        )

        :ok

      {:error, cs} ->
        Logger.warning(
          "[Staff] could not add person #{person.uuid} to team #{team_uuid}: #{inspect(cs.errors)}"
        )

        :error
    end
  end

  defp create_flash(:created, :ok, email) do
    {:info,
     gettext(
       "Staff created. %{email} can claim their account by signing up or logging in via OAuth.",
       email: email
     )}
  end

  defp create_flash(:created, :error, email) do
    {:warning,
     gettext(
       "Staff created for %{email}, but could not be added to the selected team. Please add them from the team page.",
       email: email
     )}
  end

  defp create_flash(_existing, :ok, _email), do: {:info, gettext("Staff created.")}

  defp create_flash(_existing, :error, _email) do
    {:warning,
     gettext(
       "Staff created, but could not be added to the selected team. Please add them from the team page."
     )}
  end

  defp update_flash(:ok), do: {:info, gettext("Staff updated.")}

  defp update_flash(:error) do
    {:warning,
     gettext(
       "Staff updated, but could not be added to the selected team. Please add them from the team page."
     )}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-xl px-4 py-6 gap-4">
      <div>
        <.link navigate={Paths.people()} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Staff")}
        </.link>
        <h1 class="text-2xl font-bold mt-1">{@page_title}</h1>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <.form for={@form} id="person-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-3">
            <%= if @email_editable? do %>
              <div>
                <label class="label mb-2">
                  <span class="label-text font-semibold">{gettext("Email")}</span>
                  <%= if @live_action == :edit do %>
                    <span class="label-text-alt text-base-content/50 font-normal">
                      {gettext("(editable — account not yet claimed)")}
                    </span>
                  <% end %>
                </label>
                <input
                  type="email"
                  name="email"
                  value={@email}
                  list="staff-email-suggestions"
                  placeholder={gettext("Type or pick an email")}
                  autocomplete="off"
                  required
                  class="input w-full"
                />
                <datalist :if={@live_action == :new} id="staff-email-suggestions">
                  <option :for={u <- @eligible_users} value={u.email}>
                    {[u.first_name, u.last_name] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")}
                  </option>
                </datalist>
                <div class="mt-1 text-xs">
                  <%= case @email_status do %>
                    <% :blank -> %>
                      <span class="text-base-content/50">
                        <%= if @live_action == :new do %>
                          {gettext("Existing accounts suggested. Typing a new email creates an unregistered placeholder — they'll claim it on signup or OAuth login.")}
                        <% else %>
                          {gettext("You can rename a placeholder account while nobody has claimed it yet.")}
                        <% end %>
                      </span>
                    <% :invalid -> %>
                      <span class="text-error">{gettext("Not a valid email.")}</span>
                    <% :has_profile -> %>
                      <span class="text-error">
                        <.icon name="hero-exclamation-circle" class="w-3 h-3 inline" />
                        {gettext("This user already has a staff profile.")}
                      </span>
                    <% {:existing, _user} -> %>
                      <span class="text-success">
                        <.icon name="hero-check-circle" class="w-3 h-3 inline" />
                        {gettext("Will link to existing account.")}
                      </span>
                    <% :new -> %>
                      <span class="text-info">
                        <.icon name="hero-user-plus" class="w-3 h-3 inline" />
                        {gettext("Will create a placeholder account — person claims it on signup.")}
                      </span>
                  <% end %>
                </div>
              </div>
            <% else %>
              <div>
                <label class="label mb-2">
                  <span class="label-text font-semibold">{gettext("User")}</span>
                  <span class="label-text-alt text-base-content/50 font-normal">
                    <.icon name="hero-lock-closed" class="w-3 h-3 inline" /> {gettext("locked")}
                  </span>
                </label>
                <div class="font-mono text-sm bg-base-200 px-3 py-2 rounded">
                  {@email}
                </div>
              </div>
            <% end %>

            <div class="divider text-xs text-base-content/50 my-0">{gettext("Employment")}</div>

            <.input field={@form[:job_title]} label={gettext("Job title")} placeholder={gettext("e.g. Senior Engineer")} />

            <.select
              field={@form[:employment_type]}
              label={gettext("Employment type")}
              options={[
                {gettext("Full-time"), "full_time"},
                {gettext("Part-time"), "part_time"},
                {gettext("Contractor"), "contractor"},
                {gettext("Intern"), "intern"},
                {gettext("Temporary"), "temporary"}
              ]}
              prompt={gettext("—")}
            />

            <div class="grid grid-cols-2 gap-2">
              <.input field={@form[:employment_start_date]} label={gettext("Start date")} type="date" />
              <.input field={@form[:employment_end_date]} label={gettext("End date")} type="date" />
            </div>

            <.input
              field={@form[:work_location]}
              label={gettext("Work location")}
              placeholder={gettext("e.g. Remote, Tallinn HQ, Hybrid - Berlin")}
            />

            <.select
              field={@form[:status]}
              label={gettext("Status")}
              options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
            />

            <div class="divider text-xs text-base-content/50 my-0">{gettext("Organization")}</div>

            <.select
              field={@form[:primary_department_uuid]}
              label={gettext("Primary department")}
              options={@dept_options}
              prompt={gettext("None")}
            />
            <%= if @team_options != [] do %>
              <.select
                name="team_uuid"
                label={gettext("Team")}
                value={@selected_team_uuid}
                options={@team_options}
                prompt={gettext("None")}
              />
            <% end %>

            <div class="divider text-xs text-base-content/50 my-0">{gettext("Contact & bio")}</div>

            <div class="grid grid-cols-2 gap-2">
              <.input field={@form[:work_phone]} label={gettext("Work phone")} placeholder={gettext("+372 ...")} />
              <.input field={@form[:personal_phone]} label={gettext("Personal phone")} placeholder={gettext("+372 ...")} />
            </div>

            <.textarea field={@form[:bio]} label={gettext("Bio")} placeholder={gettext("A short summary about this person")} />

            <.input
              field={@form[:skills]}
              label={gettext("Skills")}
              placeholder={gettext("comma-separated, e.g. Elixir, Phoenix, PostgreSQL")}
            />

            <div class="divider text-xs text-base-content/50 my-0">{gettext("Personal")}</div>

            <.input field={@form[:date_of_birth]} label={gettext("Date of birth")} type="date" />
            <.input
              field={@form[:personal_email]}
              label={gettext("Personal email")}
              type="email"
              placeholder={gettext("non-work email")}
            />

            <div class="divider text-xs text-base-content/50 my-0">{gettext("Emergency contact")}</div>

            <div class="grid grid-cols-2 gap-2">
              <.input field={@form[:emergency_contact_name]} label={gettext("Name")} placeholder={gettext("Contact's full name")} />
              <.input
                field={@form[:emergency_contact_relationship]}
                label={gettext("Relationship")}
                placeholder={gettext("e.g. spouse, parent")}
              />
            </div>
            <.input field={@form[:emergency_contact_phone]} label={gettext("Phone")} placeholder={gettext("+372 ...")} />

            <div class="divider text-xs text-base-content/50 my-0">{gettext("Admin notes")}</div>

            <.textarea
              field={@form[:notes]}
              label={gettext("Internal notes")}
              placeholder={gettext("Only visible to admins editing this profile")}
            />

            <div class="flex justify-end gap-2 mt-4">
              <.link navigate={Paths.people()} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
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
