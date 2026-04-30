defmodule PhoenixKitStaff.Paths do
  @moduledoc """
  Centralized path helpers for the Staff module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/staff"

  @doc "Staff dashboard root."
  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  # Departments
  @doc "Departments index."
  @spec departments() :: String.t()
  def departments, do: Routes.path("#{@base}/departments")
  @doc "New-department form."
  @spec new_department() :: String.t()
  def new_department, do: Routes.path("#{@base}/departments/new")
  @doc "Show page for a single department."
  @spec department(UUIDv7.t() | String.t()) :: String.t()
  def department(id), do: Routes.path("#{@base}/departments/#{id}")
  @doc "Edit form for a department."
  @spec edit_department(UUIDv7.t() | String.t()) :: String.t()
  def edit_department(id), do: Routes.path("#{@base}/departments/#{id}/edit")

  # Teams
  @doc "Teams index."
  @spec teams() :: String.t()
  def teams, do: Routes.path("#{@base}/teams")
  @doc "New-team form."
  @spec new_team() :: String.t()
  def new_team, do: Routes.path("#{@base}/teams/new")
  @doc "Show page for a single team."
  @spec team(UUIDv7.t() | String.t()) :: String.t()
  def team(id), do: Routes.path("#{@base}/teams/#{id}")
  @doc "Edit form for a team."
  @spec edit_team(UUIDv7.t() | String.t()) :: String.t()
  def edit_team(id), do: Routes.path("#{@base}/teams/#{id}/edit")

  # People (staff)
  @doc "Staff index (people list)."
  @spec people() :: String.t()
  def people, do: Routes.path("#{@base}/people")
  @doc "New-person form."
  @spec new_person() :: String.t()
  def new_person, do: Routes.path("#{@base}/people/new")
  @doc "Show page for a single person."
  @spec person(UUIDv7.t() | String.t()) :: String.t()
  def person(id), do: Routes.path("#{@base}/people/#{id}")
  @doc "Edit form for a person."
  @spec edit_person(UUIDv7.t() | String.t()) :: String.t()
  def edit_person(id), do: Routes.path("#{@base}/people/#{id}/edit")
end
