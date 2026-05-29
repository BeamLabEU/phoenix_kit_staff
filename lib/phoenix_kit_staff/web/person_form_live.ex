defmodule PhoenixKitStaff.Web.PersonFormLive do
  @moduledoc "Create or edit a staff person."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.MultilangForm

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKitStaff.{Activity, Departments, Errors, Paths, Staff, Teams}
  alias PhoenixKitStaff.Schemas.Person
  alias PhoenixKitStaff.Web.Helpers

  @translatable_field_atoms [:job_title, :bio, :skills, :notes]

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> mount_multilang()
     |> apply_action(socket.assigns.live_action, params)}
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
      selected_team_uuid: nil,
      location_options: location_options()
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
          selected_team_uuid: nil,
          location_options: location_options()
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

  # Soft dep on `phoenix_kit_locations` — staff has no compile-time
  # link to that package. Returns `[]` when the module isn't installed
  # or is toggled off in Admin > Modules; the form hides the picker in
  # that case. Rescues DB errors so a transient outage on the
  # locations side doesn't take this form down with it.
  defp location_options do
    # Resolve the optional module through `Code.ensure_loaded/1`: binding
    # `mod` to the runtime result keeps PhoenixKitLocations out of
    # compile-time analysis, so a missing dep neither trips the compiler's
    # undefined-function warning (`--warnings-as-errors`) nor dialyzer —
    # and we avoid `apply/3` (and the credo finding that comes with it).
    with true <- locations_module_enabled?(),
         {:module, mod} <- Code.ensure_loaded(PhoenixKitLocations.Locations) do
      try do
        mod.list_locations(status: "active")
        |> Enum.map(fn loc -> {loc.name, loc.uuid} end)
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
    # Same soft-dep dispatch: `mod` comes from a runtime lookup, so the
    # optional PhoenixKitLocations is never named at compile time;
    # `function_exported?/3` gates the call.
    case Code.ensure_loaded(PhoenixKitLocations) do
      {:module, mod} -> function_exported?(mod, :enabled?, 0) and mod.enabled?()
      {:error, _} -> false
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  # Folds in-flight secondary-tab translations into attrs and
  # preserves primary-tab column values that the current secondary-tab
  # DOM didn't include. Same shape as Department / Team forms.
  defp merge_attrs(attrs, socket) do
    in_flight = Helpers.in_flight_record(socket, :form, :person)
    Helpers.merge_translations_attrs(attrs, in_flight, Person.translatable_fields())
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang}, socket) do
    {:noreply, handle_switch_language(socket, lang)}
  end

  def handle_event("validate", %{"person" => attrs} = params, socket) do
    attrs = merge_attrs(attrs, socket)

    cs =
      socket.assigns.person
      |> Staff.change_person(attrs)
      |> Map.put(:action, :validate)

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
    attrs = merge_attrs(attrs, socket)
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

      {:error, atom} when is_atom(atom) ->
        Helpers.log_operation_error("staff.person_created", socket,
          reason: atom,
          resource_type: "staff_person",
          metadata: %{"attempted_email" => email}
        )

        {:noreply, put_flash(socket, :error, Errors.message(atom))}

      {:error, %Ecto.Changeset{} = cs} ->
        Helpers.log_operation_error("staff.person_created", socket,
          reason: cs,
          resource_type: "staff_person",
          metadata: %{"attempted_email" => email}
        )

        {:noreply,
         socket
         |> Helpers.maybe_switch_to_primary_on_error(cs, @translatable_field_atoms)
         |> assign_form(cs)}
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

      {:error, atom} when is_atom(atom) ->
        Helpers.log_operation_error("staff.person_updated", socket,
          reason: atom,
          resource_type: "staff_person",
          resource_uuid: socket.assigns.person.uuid,
          target_uuid: socket.assigns.person.user_uuid,
          metadata: %{"attempted_email" => new_email, "phase" => "rename_email"}
        )

        {:noreply, put_flash(socket, :error, Errors.message(atom))}

      {:error, %Ecto.Changeset{} = cs} ->
        Helpers.log_operation_error("staff.person_updated", socket,
          reason: cs,
          resource_type: "staff_person",
          resource_uuid: socket.assigns.person.uuid,
          target_uuid: socket.assigns.person.user_uuid,
          metadata: %{"phase" => "rename_email"}
        )

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
        Helpers.log_operation_error("staff.person_updated", socket,
          reason: cs,
          resource_type: "staff_person",
          resource_uuid: socket.assigns.person.uuid,
          target_uuid: socket.assigns.person.user_uuid
        )

        {:noreply,
         socket
         |> Helpers.maybe_switch_to_primary_on_error(cs, @translatable_field_atoms)
         |> assign_form(cs)}
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
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <.admin_page_header
        title={@page_title}
        subtitle={
          if @live_action == :new,
            do: gettext("Add a new person on staff."),
            else: gettext("Update staff profile.")
        }
      />

      <div class="card bg-base-100 shadow max-w-3xl mx-auto w-full">
        <.form
          for={@form}
          id="person-form"
          phx-change="validate"
          phx-submit="save"
          phx-debounce="300"
        >
          <%!-- All translatable fields grouped together at the top
               so the user can see at a glance what's translatable.
               The wrapper re-mounts everything inside on language
               switch — fine here because the whole block IS
               translatable; non-translatable fields live below as
               siblings outside the wrapper. --%>
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
          >
            <div class="card-body pt-3 pb-6 flex flex-col gap-3">
              <.translatable_field
                field_name="job_title"
                form_prefix="person"
                changeset={@form.source}
                schema_field={:job_title}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"person[translations][#{@current_lang}][job_title]"}
                lang_data_key="job_title"
                label={gettext("Job title")}
                placeholder={gettext("e.g. Senior Engineer")}
              />

              <.translatable_field
                field_name="bio"
                form_prefix="person"
                changeset={@form.source}
                schema_field={:bio}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"person[translations][#{@current_lang}][bio]"}
                lang_data_key="bio"
                label={gettext("Bio")}
                type="textarea"
                placeholder={gettext("A short summary about this person")}
              />

              <.translatable_field
                field_name="skills"
                form_prefix="person"
                changeset={@form.source}
                schema_field={:skills}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"person[translations][#{@current_lang}][skills]"}
                lang_data_key="skills"
                label={gettext("Skills")}
                type="textarea"
                placeholder={gettext("Languages, technologies, certifications, anything else worth noting…")}
              />

              <.translatable_field
                field_name="notes"
                form_prefix="person"
                changeset={@form.source}
                schema_field={:notes}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"person[translations][#{@current_lang}][notes]"}
                lang_data_key="notes"
                label={gettext("Internal notes")}
                type="textarea"
                placeholder={gettext("Only visible to admins editing this profile")}
              />
            </div>
          </.multilang_fields_wrapper>

          <%!-- Visual gap between the translatable block above and
               the non-translatable section below. daisyUI's
               `.divider` reliably renders a horizontal line with its
               own breathing room, no Tailwind class-extraction
               surprises. --%>
          <div class="divider mx-6 my-0"></div>

          <%!-- Non-translatable fields: email, employment metadata,
               organization, contact, personal, emergency contact. --%>
          <div class="card-body pt-2 flex flex-col gap-3">
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

            <%!-- Name lives on Person (not User) — staff profiles
                 have their own lifecycle and placeholder users
                 created via `find_or_create_user_by_email/1` are
                 anonymous until claimed. --%>
            <.input
              field={@form[:name]}
              label={gettext("Full name")}
              placeholder={gettext("e.g. Jane Smith")}
            />

            <div class="divider text-xs text-base-content/50 my-0">{gettext("Employment")}</div>

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

            <%!-- Work location is a soft-FK to a `phoenix_kit_locations`
                 row (UUID stored as a plain string in the column). The
                 whole field is hidden when the locations module isn't
                 installed or is toggled off — single-location
                 deployments don't need it. --%>
            <.select
              :if={@location_options != []}
              field={@form[:work_location]}
              label={gettext("Work location")}
              options={@location_options}
              prompt={gettext("—")}
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

            <div class="divider text-xs text-base-content/50 my-0">{gettext("Contact")}</div>

            <div class="grid grid-cols-2 gap-2">
              <.input field={@form[:work_phone]} label={gettext("Work phone")} placeholder={gettext("+372 ...")} />
              <.input field={@form[:personal_phone]} label={gettext("Personal phone")} placeholder={gettext("+372 ...")} />
            </div>

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

            <div class="flex justify-end gap-2 mt-4">
              <.link navigate={Paths.people()} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
              <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
              </button>
            </div>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
