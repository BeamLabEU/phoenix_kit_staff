defmodule PhoenixKitStaff.Paths do
  @moduledoc """
  Centralized path helpers for the Staff module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/staff"

  @doc "Staff dashboard root."
  def index, do: Routes.path(@base)

  # Departments
  @doc "Departments index."
  def departments, do: Routes.path("#{@base}/departments")
  @doc "New-department form."
  def new_department, do: Routes.path("#{@base}/departments/new")
  @doc "Show page for a single department."
  def department(id), do: Routes.path("#{@base}/departments/#{id}")
  @doc "Edit form for a department."
  def edit_department(id), do: Routes.path("#{@base}/departments/#{id}/edit")

  # Teams
  @doc "Teams index."
  def teams, do: Routes.path("#{@base}/teams")
  @doc "New-team form."
  def new_team, do: Routes.path("#{@base}/teams/new")
  @doc "Show page for a single team."
  def team(id), do: Routes.path("#{@base}/teams/#{id}")
  @doc "Edit form for a team."
  def edit_team(id), do: Routes.path("#{@base}/teams/#{id}/edit")

  # People (staff)
  def people, do: Routes.path("#{@base}/people")
  @doc "New-person form."
  def new_person, do: Routes.path("#{@base}/people/new")
  @doc "Show page for a single person."
  def person(id), do: Routes.path("#{@base}/people/#{id}")
  @doc "Edit form for a person."
  def edit_person(id), do: Routes.path("#{@base}/people/#{id}/edit")
end
