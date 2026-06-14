defmodule PhoenixKitStaff.Web.PersonFormLive do
  @moduledoc "Create or edit a staff person."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  import PhoenixKitWeb.Components.MultilangForm

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKitStaff.{Activity, Departments, Errors, Paths, Skills, Staff, Teams}
  alias PhoenixKitStaff.Schemas.{Person, PersonSkill}
  alias PhoenixKitStaff.Web.Helpers

  @translatable_field_atoms [:job_title, :bio]

  # How many skill matches to surface in the type-to-search dropdown.
  @skill_match_limit 8

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> mount_multilang()
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    person = %Person{}
    all_skills = skill_options()

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
      location_options: location_options(),
      all_skills: all_skills,
      staged_skills: [],
      skill_search: "",
      skill_matches: skill_matches("", [], all_skills)
    )
    |> assign_form(Staff.change_person(person))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Staff.get_person(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Staff not found."))
        |> push_navigate(to: Paths.people())

      %Person{status: "trashed"} = person ->
        # A trashed profile can't be edited in place — that would
        # un-trash it through the normal update path, skipping the
        # restore semantics (prior-status + metadata cleanup). Send the
        # admin to the show page, which offers an explicit Restore.
        socket
        |> put_flash(:error, gettext("Restore this staff before editing."))
        |> push_navigate(to: Paths.person(person.uuid))

      person ->
        all_skills = skill_options()
        staged = load_staged_skills(person.uuid)

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
          location_options: location_options(),
          all_skills: all_skills,
          staged_skills: staged,
          skill_search: "",
          skill_matches: skill_matches("", staged, all_skills)
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

    # Skills are staged client-side: the type-to-search box and the per-chip
    # level selects ride along on this same form change. Keep the search +
    # matches live, and fold any level edits into the staged list so they're
    # in hand when the user finally presses Save (nothing is persisted yet).
    search = Map.get(params, "skill_search", socket.assigns.skill_search)
    staged = sync_staged_levels(socket.assigns.staged_skills, params["skills"])

    {:noreply,
     socket
     |> assign_form(cs)
     |> assign(
       email: email,
       email_status: email_status(email, socket.assigns.eligible_users),
       team_options: team_options_for(blank_to_nil(dept_uuid)),
       selected_team_uuid: blank_to_nil(team_uuid),
       staged_skills: staged,
       skill_search: search,
       skill_matches: skill_matches(search, staged, socket.assigns.all_skills)
     )}
  end

  def handle_event("add_staged_skill", %{"uuid" => uuid}, socket) do
    staged =
      case Enum.find(socket.assigns.all_skills, &(&1.uuid == uuid)) do
        nil ->
          socket.assigns.staged_skills

        %{name: name} ->
          if Enum.any?(socket.assigns.staged_skills, &(&1.skill_uuid == uuid)),
            do: socket.assigns.staged_skills,
            else: socket.assigns.staged_skills ++ [%{skill_uuid: uuid, name: name, level: nil}]
      end

    {:noreply,
     assign(socket,
       staged_skills: staged,
       skill_search: "",
       skill_matches: skill_matches("", staged, socket.assigns.all_skills)
     )}
  end

  def handle_event("remove_staged_skill", %{"uuid" => uuid}, socket) do
    staged = Enum.reject(socket.assigns.staged_skills, &(&1.skill_uuid == uuid))

    {:noreply,
     assign(socket,
       staged_skills: staged,
       skill_matches:
         skill_matches(socket.assigns.skill_search, staged, socket.assigns.all_skills)
     )}
  end

  # Re-query the skill taxonomy when the window regains focus — the user may
  # have just created a skill on the Skills admin page (opened in a new tab
  # from the picker). Flips the empty state to the picker and surfaces new
  # skills in search without a manual reload.
  def handle_event("refresh_skills", _params, socket) do
    all_skills = skill_options()

    {:noreply,
     assign(socket,
       all_skills: all_skills,
       skill_matches:
         skill_matches(socket.assigns.skill_search, socket.assigns.staged_skills, all_skills)
     )}
  end

  def handle_event("save", %{"person" => attrs} = params, socket) do
    attrs = merge_attrs(attrs, socket)
    email = Map.get(params, "email", "") |> String.trim()
    team_uuid = blank_to_nil(params["team_uuid"])
    # Final level sync from the submitted form — covers a level select that
    # changed without a preceding validate round-trip. Skills persist only
    # here, after the person upsert succeeds (see `sync_skills/2`).
    socket =
      assign(
        socket,
        :staged_skills,
        sync_staged_levels(socket.assigns.staged_skills, params["skills"])
      )

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

        sync_skills(socket, person)

        {kind, flash} = create_flash(status_tag, team_result, email)

        {:noreply,
         socket
         |> put_flash(kind, flash)
         |> push_navigate(to: Paths.person(person.uuid))}

      {:error, {:trashed_person_exists, trashed}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "A trashed staff profile already exists for this email — restore it instead of creating a new one."
           )
         )
         |> push_navigate(to: Paths.person(trashed.uuid))}

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
    # Re-fetch before saving: the edit LV may have been open since before
    # another admin trashed (or deleted) this person. Editing a trashed
    # row would un-trash it through the normal update path, bypassing the
    # restore semantics — so re-check the *current* DB state and bail.
    case Staff.get_person(socket.assigns.person.uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Staff not found."))
         |> push_navigate(to: Paths.people())}

      %Person{status: "trashed"} = person ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Restore this staff before editing."))
         |> push_navigate(to: Paths.person(person.uuid))}

      current ->
        do_update_person(socket, current, attrs, team_uuid)
    end
  end

  defp do_update_person(socket, current, attrs, team_uuid) do
    case Staff.update_person(current, attrs) do
      {:ok, person} ->
        team_result = maybe_add_to_team(socket, person, team_uuid)

        Activity.log("staff.person_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid,
          metadata: %{}
        )

        sync_skills(socket, person)

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

  # ── Skills (staged on the form, persisted only on Save) ────────────

  # All skills as lightweight `%{uuid, name}` maps for the picker.
  defp skill_options do
    Skills.list() |> Enum.map(&%{uuid: &1.uuid, name: &1.name})
  end

  # A person's current assignments as staged entries (`level` = the
  # proficiency level, `nil` when unset).
  defp load_staged_skills(person_uuid) do
    person_uuid
    |> Skills.list_for_person()
    |> Enum.map(&%{skill_uuid: &1.skill_uuid, name: &1.skill.name, level: &1.proficiency_level})
  end

  # Skills not yet staged, filtered by the (case-insensitive) query, capped.
  defp skill_matches(query, staged, all_skills) do
    staged_uuids = MapSet.new(staged, & &1.skill_uuid)
    q = query |> to_string() |> String.trim() |> String.downcase()

    all_skills
    |> Enum.reject(&MapSet.member?(staged_uuids, &1.uuid))
    |> then(fn skills ->
      if q == "",
        do: skills,
        else: Enum.filter(skills, &String.contains?(String.downcase(&1.name), q))
    end)
    |> Enum.take(@skill_match_limit)
  end

  # Folds per-chip level edits (`skills[<uuid>][level]` form params) back
  # into the staged list. Unknown/absent params leave the staged list as-is.
  defp sync_staged_levels(staged, params) when is_map(params) do
    Enum.map(staged, fn s ->
      case params[s.skill_uuid] do
        %{"level" => level} -> %{s | level: blank_to_nil(level)}
        _ -> s
      end
    end)
  end

  defp sync_staged_levels(staged, _params), do: staged

  # Reconciles the DB assignments with the staged list after a successful
  # person upsert: unassign what was removed, assign what's new, re-level
  # what changed. Logs one activity row per change.
  defp sync_skills(socket, person) do
    desired = Map.new(socket.assigns.staged_skills, &{&1.skill_uuid, &1.level})
    current = Skills.list_for_person(person.uuid)
    current_map = Map.new(current, &{&1.skill_uuid, &1})
    actor = Activity.actor_uuid(socket)

    current
    |> Enum.reject(&Map.has_key?(desired, &1.skill_uuid))
    |> Enum.each(fn ps ->
      with {:ok, _} <- Skills.unassign_skill(ps) do
        log_skill_change(
          actor,
          "staff.person_skill_removed",
          ps.skill_uuid,
          person.user_uuid,
          %{}
        )
      end
    end)

    Enum.each(desired, fn {skill_uuid, level} ->
      case current_map[skill_uuid] do
        nil ->
          with {:ok, ps} <- Skills.assign_skill(person.uuid, skill_uuid, level) do
            log_skill_change(actor, "staff.person_skill_added", skill_uuid, person.user_uuid, %{
              "person_skill_uuid" => ps.uuid,
              "proficiency_level" => level
            })
          end

        %PersonSkill{proficiency_level: ^level} ->
          :ok

        %PersonSkill{} = ps ->
          with {:ok, _} <- Skills.update_assignment_level(ps, level) do
            log_skill_change(actor, "staff.person_skill_updated", skill_uuid, person.user_uuid, %{
              "proficiency_level" => level
            })
          end
      end
    end)

    :ok
  end

  defp log_skill_change(actor, action, skill_uuid, target_uuid, metadata) do
    Activity.log(action,
      actor_uuid: actor,
      resource_type: "skill",
      resource_uuid: skill_uuid,
      target_uuid: target_uuid,
      metadata: metadata
    )
  end

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
                  <span class="label-text font-semibold">{Gettext.gettext(PhoenixKitWeb.Gettext, "Email")}</span>
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
                  <span class="label-text font-semibold">{Gettext.gettext(PhoenixKitWeb.Gettext, "User")}</span>
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
              prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "—")}
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
              prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "—")}
            />

            <.select
              field={@form[:status]}
              label={Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}
              options={[{Gettext.gettext(PhoenixKitWeb.Gettext, "Active"), "active"}, {Gettext.gettext(PhoenixKitWeb.Gettext, "Inactive"), "inactive"}]}
            />

            <div class="divider text-xs text-base-content/50 my-0">{Gettext.gettext(PhoenixKitWeb.Gettext, "Organization")}</div>

            <.select
              field={@form[:primary_department_uuid]}
              label={gettext("Primary department")}
              options={@dept_options}
              prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "None")}
            />
            <%= if @team_options != [] do %>
              <.select
                name="team_uuid"
                label={gettext("Team")}
                value={@selected_team_uuid}
                options={@team_options}
                prompt={Gettext.gettext(PhoenixKitWeb.Gettext, "None")}
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
              <.input field={@form[:emergency_contact_name]} label={Gettext.gettext(PhoenixKitWeb.Gettext, "Name")} placeholder={gettext("Contact's full name")} />
              <.input
                field={@form[:emergency_contact_relationship]}
                label={gettext("Relationship")}
                placeholder={gettext("e.g. spouse, parent")}
              />
            </div>
            <.input field={@form[:emergency_contact_phone]} label={gettext("Phone")} placeholder={gettext("+372 ...")} />

            <div class="divider text-xs text-base-content/50 my-0">{gettext("Skills")}</div>

            <%!-- Skills are staged on the form and written to the database
                 only when Save is pressed (below). Each row's hidden +
                 level inputs POST with the person form; add/remove restage
                 in-memory via phx-click — no DB write happens here. The
                 rows + search field mirror the form's other fields (full
                 width, `label-text font-semibold` labels, `input w-full`).

                 Skills are a global taxonomy created on the Skills admin
                 page, so the picker only assigns *existing* ones. The
                 "Add / edit skills" link opens that page in a new tab so
                 in-progress form edits survive; `phx-window-focus`
                 re-queries on return, flipping the empty state to the
                 picker (and surfacing freshly-created skills) without a
                 manual reload. --%>
            <div phx-window-focus="refresh_skills" class="flex flex-col gap-3">
              <div :if={@all_skills == []}>
                <label class="label mb-2">
                  <span class="label-text font-semibold">{gettext("Add a skill")}</span>
                </label>
                <p class="text-sm text-base-content/60">
                  {gettext("No skills have been created yet.")}
                  <.link
                    href={Paths.skills()}
                    target="_blank"
                    rel="noopener"
                    class="link link-primary"
                  >
                    {gettext("Add / edit skills")}
                  </.link>
                </p>
              </div>

              <div :if={@all_skills != []} class="flex flex-col gap-3">
                <div :if={@staged_skills != []} class="flex flex-col gap-2">
                  <div
                    :for={s <- @staged_skills}
                    class="flex items-center gap-2 rounded-box border border-base-300 px-3 py-2"
                  >
                    <input type="hidden" name={"skills[#{s.skill_uuid}][skill_uuid]"} value={s.skill_uuid} />
                    <span class="flex-1 font-medium truncate">{s.name}</span>
                    <select name={"skills[#{s.skill_uuid}][level]"} class="select select-sm w-40">
                      <option value="" selected={is_nil(s.level)}>{PersonSkill.proficiency_label(nil)}</option>
                      <option
                        :for={lvl <- PersonSkill.proficiency_levels()}
                        value={lvl}
                        selected={s.level == lvl}
                      >
                        {PersonSkill.proficiency_label(lvl)}
                      </option>
                    </select>
                    <button
                      type="button"
                      phx-click="remove_staged_skill"
                      phx-value-uuid={s.skill_uuid}
                      class="btn btn-ghost btn-sm btn-circle text-error"
                      aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                </div>

                <div>
                  <label class="label mb-2">
                    <span class="label-text font-semibold">{gettext("Add a skill")}</span>
                    <.link
                      href={Paths.skills()}
                      target="_blank"
                      rel="noopener"
                      class="label-text-alt link link-primary"
                    >
                      {gettext("Add / edit skills")}
                    </.link>
                  </label>
                  <div class="relative">
                    <input
                      type="text"
                      name="skill_search"
                      value={@skill_search}
                      autocomplete="off"
                      placeholder={gettext("Type to search skills…")}
                      class="input w-full transition-colors focus:input-primary"
                    />
                    <ul
                      :if={@skill_matches != []}
                      class="menu menu-sm bg-base-100 border border-base-300 rounded-box mt-1 w-full shadow absolute z-20"
                    >
                      <li :for={skill <- @skill_matches}>
                        <button type="button" phx-click="add_staged_skill" phx-value-uuid={skill.uuid}>
                          <.icon name="hero-plus" class="w-4 h-4" /> {skill.name}
                        </button>
                      </li>
                    </ul>
                    <p
                      :if={@skill_search != "" and @skill_matches == []}
                      class="text-xs text-base-content/50 mt-1"
                    >
                      {gettext("No matching skills.")}
                      <.link
                        href={Paths.skills()}
                        target="_blank"
                        rel="noopener"
                        class="link link-primary"
                      >
                        {gettext("Add / edit skills")}
                      </.link>
                    </p>
                  </div>
                </div>
              </div>
            </div>

            <div class="flex justify-end gap-2 mt-4">
              <.link navigate={Paths.people()} class="btn btn-ghost btn-sm">{Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}</.link>
              <button type="submit" phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Saving…")} class="btn btn-primary btn-sm">
                <%= if @live_action == :new, do: gettext("Create"), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Save") %>
              </button>
            </div>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
