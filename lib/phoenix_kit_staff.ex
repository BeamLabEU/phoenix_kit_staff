defmodule PhoenixKitStaff do
  @moduledoc """
  Staff module for PhoenixKit.

  Manages departments, teams, people (staff linked to
  `PhoenixKit.Users.Auth.User`), and skills.

  Registers one parent admin tab `Staff` with visible subtabs for
  Overview, Departments, Teams, Staff, and Skills, plus hidden subtabs for
  new/edit/show forms.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  @version Mix.Project.config()[:version]

  # Tab labels are translated at render time via each `%Tab{}`'s
  # `gettext_backend`, so they aren't `gettext/1` call sites and wouldn't be
  # picked up by `mix gettext.extract`. List them through `gettext_noop/1`
  # (extracts the msgid without translating here) so they stay in the staff
  # domain `.po`. Title-case here mirrors the nav labels; the sentence-case
  # page titles (`"New department"`, etc.) are separate LV strings.
  @doc false
  def __tab_label_strings__ do
    [
      gettext_noop("Staff"),
      gettext_noop("Overview"),
      gettext_noop("New Department"),
      gettext_noop("Edit Department"),
      gettext_noop("New Team"),
      gettext_noop("Edit Team"),
      gettext_noop("New Staff"),
      gettext_noop("Edit Staff"),
      gettext_noop("Skills"),
      gettext_noop("New Skill"),
      gettext_noop("Edit Skill"),
      gettext_noop("Skill")
    ]
  end

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  # ── Required callbacks ────────────────────────────────────────────

  @impl PhoenixKit.Module
  def module_key, do: "staff"

  @impl PhoenixKit.Module
  def module_name, do: "Staff"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("staff_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    Settings.update_boolean_setting_with_module("staff_enabled", true, module_key())
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("staff_enabled", false, module_key())
  end

  # ── Optional callbacks ────────────────────────────────────────────

  @impl PhoenixKit.Module
  def version, do: @version

  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKitStaff.Migrations

  @doc """
  The manifest of this module's tables, for `mix phoenix_kit.repair` and
  `mix phoenix_kit.doctor`; see `PhoenixKitStaff.ExpectedSchema`.
  """
  @impl PhoenixKit.Module
  def expected_schema, do: PhoenixKitStaff.ExpectedSchema

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Staff",
      icon: "hero-users",
      description: "Manage departments, teams, and staff",
      sub_permissions: [
        # Date of birth, personal email and phone, emergency contact and
        # private notes are more than the staff directory should show to
        # everyone who can open it. `migrate_legacy/0` grants this once to
        # every role that held the base key before it existed.
        %{
          key: "view_personal",
          label: "See and edit personal details",
          description:
            "Date of birth, personal email and phone, emergency contact and private notes of staff"
        }
      ]
    }
  end

  @doc """
  The composed key of the personal-details sub-permission, for
  `Scope.can?/2`. Without it the people pages hide `Person.personal_fields/0`
  and a save never writes them.
  """
  @spec view_personal_permission() :: String.t()
  def view_personal_permission, do: module_key() <> ".view_personal"

  # Set once `staff.view_personal` has been carried to the roles that held
  # the base key before it existed, so it never runs again and an Owner's
  # revoke sticks.
  @view_personal_backfill_key "staff_view_personal_backfilled"

  @impl PhoenixKit.Module
  @doc """
  One-time data repairs core runs at boot. Grants `staff.view_personal`
  once to every role that already holds `staff`, so nobody loses the
  personal details they could see before the key was split out; a role
  created or granted `staff` later gets the narrow meaning. The flag is set
  only after every grant succeeded, so a failed pass retries next boot.
  """
  def migrate_legacy do
    if Settings.get_setting(@view_personal_backfill_key) == "true" do
      {:ok, %{view_personal_backfill: :already_backfilled}}
    else
      backfill_view_personal()
    end
  rescue
    e ->
      Logger.warning("[Staff] view_personal backfill raised: exception=#{inspect(e.__struct__)}")

      {:error, :backfill_failed}
  end

  defp backfill_view_personal do
    alias PhoenixKit.Users.Permissions

    key = view_personal_permission()

    with {:ok, role_uuids} <- roles_lacking(module_key(), key),
         results = Enum.map(role_uuids, &Permissions.grant_permission(&1, key, nil)),
         true <- Enum.all?(results, &match?({:ok, _}, &1)),
         {:ok, _} <-
           Settings.update_setting_with_module(@view_personal_backfill_key, "true", module_key()) do
      {:ok, %{view_personal_backfill: :backfilled}}
    else
      {:error, :lookup_failed} = error ->
        Logger.warning("[Staff] view_personal backfill could not read grants; retrying")
        error

      _ ->
        Logger.warning("[Staff] view_personal backfill incomplete; retrying next boot")
        {:error, :grant_failed}
    end
  end

  # Roles holding `base` but not `key`, read with a query that RAISES on a
  # database error. Core's `Permissions.get_permissions_for_role/1` rescues
  # to `[]`, which would read as "nobody holds the base key" and set the
  # flag for good.
  @doc false
  def roles_lacking(base, key) do
    import Ecto.Query, only: [from: 2]

    repo = PhoenixKit.RepoHelper.repo()

    holders =
      from(rp in PhoenixKit.Users.RolePermission,
        where: rp.module_key == ^base,
        select: rp.role_uuid
      )
      |> repo.all()

    have =
      from(rp in PhoenixKit.Users.RolePermission,
        where: rp.module_key == ^key,
        select: rp.role_uuid
      )
      |> repo.all()
      |> MapSet.new()

    {:ok, holders |> Enum.uniq() |> Enum.reject(&MapSet.member?(have, &1))}
  rescue
    _ -> {:error, :lookup_failed}
  end

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_staff]

  @impl PhoenixKit.Module
  def media_reorganizer, do: PhoenixKitStaff.MediaReorganizer

  @impl PhoenixKit.Module
  def admin_tabs do
    parent = [
      %Tab{
        id: :admin_staff,
        label: "Staff",
        gettext_backend: PhoenixKitStaff.Gettext,
        icon: "hero-users",
        path: "staff",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        # Clicking Staff opens the people list, not the overview: the sidebar
        # sends the parent to the first subtab by priority (Staff). A bare
        # /staff renders the same list, so an old link lands there too.
        redirect_to_first_subtab: true,
        live_view: {PhoenixKitStaff.Web.PeopleLive, :index}
      }
    ]

    visible_subtabs = [
      %Tab{
        id: :admin_staff_overview,
        label: "Overview",
        gettext_backend: PhoenixKitStaff.Gettext,
        icon: "hero-home",
        path: "staff/overview",
        priority: 652,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_staff,
        live_view: {PhoenixKitStaff.Web.OverviewLive, :index}
      },
      %Tab{
        id: :admin_staff_departments,
        label: "Departments",
        gettext_backend: PhoenixKitStaff.Gettext,
        icon: "hero-building-office-2",
        path: "staff/departments",
        priority: 653,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_staff,
        live_view: {PhoenixKitStaff.Web.DepartmentsLive, :index}
      },
      %Tab{
        id: :admin_staff_teams,
        label: "Teams",
        gettext_backend: PhoenixKitStaff.Gettext,
        icon: "hero-user-group",
        path: "staff/teams",
        priority: 654,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_staff,
        live_view: {PhoenixKitStaff.Web.TeamsLive, :index}
      },
      %Tab{
        id: :admin_staff_people,
        label: "Staff",
        gettext_backend: PhoenixKitStaff.Gettext,
        icon: "hero-identification",
        path: "staff/people",
        priority: 651,
        level: :admin,
        permission: module_key(),
        # The list's own pages and the bare module root, which renders the
        # same list.
        match: {:regex, ~r{(?:^|/)staff(?:/people(?:/.*)?)?$}},
        parent: :admin_staff,
        live_view: {PhoenixKitStaff.Web.PeopleLive, :index}
      },
      %Tab{
        id: :admin_staff_skills,
        label: "Skills",
        gettext_backend: PhoenixKitStaff.Gettext,
        icon: "hero-academic-cap",
        path: "staff/skills",
        priority: 655,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_staff,
        live_view: {PhoenixKitStaff.Web.SkillsLive, :index}
      }
    ]

    hidden_subtabs = [
      %Tab{
        id: :admin_staff_department_new,
        label: "New Department",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/departments/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.DepartmentFormLive, :new}
      },
      %Tab{
        id: :admin_staff_department_edit,
        label: "Edit Department",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/departments/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.DepartmentFormLive, :edit}
      },
      %Tab{
        id: :admin_staff_department_show,
        label: "Department",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/departments/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.DepartmentShowLive, :show}
      },
      %Tab{
        id: :admin_staff_team_new,
        label: "New Team",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/teams/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.TeamFormLive, :new}
      },
      %Tab{
        id: :admin_staff_team_edit,
        label: "Edit Team",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/teams/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.TeamFormLive, :edit}
      },
      %Tab{
        id: :admin_staff_team_show,
        label: "Team",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/teams/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.TeamShowLive, :show}
      },
      %Tab{
        id: :admin_staff_skill_new,
        label: "New Skill",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/skills/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.SkillFormLive, :new}
      },
      %Tab{
        id: :admin_staff_skill_edit,
        label: "Edit Skill",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/skills/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.SkillFormLive, :edit}
      },
      %Tab{
        id: :admin_staff_skill_show,
        label: "Skill",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/skills/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.SkillShowLive, :show}
      },
      %Tab{
        id: :admin_staff_person_new,
        label: "New Staff",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/people/new",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.PersonFormLive, :new}
      },
      %Tab{
        id: :admin_staff_person_edit,
        label: "Edit Staff",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/people/:id/edit",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.PersonFormLive, :edit}
      },
      %Tab{
        id: :admin_staff_person_show,
        label: "Staff",
        gettext_backend: PhoenixKitStaff.Gettext,
        path: "staff/people/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.PersonShowLive, :show}
      }
    ]

    parent ++ visible_subtabs ++ hidden_subtabs
  end
end
