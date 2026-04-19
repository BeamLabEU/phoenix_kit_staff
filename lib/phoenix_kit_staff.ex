defmodule PhoenixKitStaff do
  @moduledoc """
  Staff module for PhoenixKit.

  Manages departments, teams, and people (staff linked to
  `PhoenixKit.Users.Auth.User`).

  Registers one parent admin tab `Staff` with visible subtabs for
  Overview, Departments, Teams, and Members, plus hidden subtabs for
  new/edit/show forms.
  """

  use PhoenixKit.Module

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
  def version, do: "0.1.0"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Staff",
      icon: "hero-users",
      description: "Manage departments, teams, and staff"
    }
  end

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_staff]

  @impl PhoenixKit.Module
  def admin_tabs do
    parent = [
      %Tab{
        id: :admin_staff,
        label: "Staff",
        icon: "hero-users",
        path: "staff",
        priority: 650,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        live_view: {PhoenixKitStaff.Web.OverviewLive, :index}
      }
    ]

    visible_subtabs = [
      %Tab{
        id: :admin_staff_overview,
        label: "Overview",
        icon: "hero-home",
        path: "staff",
        priority: 651,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_staff,
        live_view: {PhoenixKitStaff.Web.OverviewLive, :index}
      },
      %Tab{
        id: :admin_staff_departments,
        label: "Departments",
        icon: "hero-building-office-2",
        path: "staff/departments",
        priority: 652,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_staff,
        live_view: {PhoenixKitStaff.Web.DepartmentsLive, :index}
      },
      %Tab{
        id: :admin_staff_teams,
        label: "Teams",
        icon: "hero-user-group",
        path: "staff/teams",
        priority: 653,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_staff,
        live_view: {PhoenixKitStaff.Web.TeamsLive, :index}
      },
      %Tab{
        id: :admin_staff_people,
        label: "Staff",
        icon: "hero-identification",
        path: "staff/people",
        priority: 654,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        parent: :admin_staff,
        live_view: {PhoenixKitStaff.Web.PeopleLive, :index}
      }
    ]

    hidden_subtabs = [
      %Tab{
        id: :admin_staff_department_new,
        label: "New Department",
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
        path: "staff/teams/:id",
        level: :admin,
        permission: module_key(),
        parent: :admin_staff,
        visible: false,
        live_view: {PhoenixKitStaff.Web.TeamShowLive, :show}
      },
      %Tab{
        id: :admin_staff_person_new,
        label: "New Staff",
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
