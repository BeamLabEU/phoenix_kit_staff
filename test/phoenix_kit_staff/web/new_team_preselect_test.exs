defmodule PhoenixKitStaff.Web.NewTeamPreselectTest do
  @moduledoc """
  "New team" on a department's page opens the form with that department
  already chosen; a department that is not one of the options is ignored.
  """
  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.Paths

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "the department page's New team preselects the department", %{conn: conn} do
    _other = fixture_department(%{"name" => "Other #{System.unique_integer([:positive])}"})
    dept = fixture_department(%{"name" => "Picked #{System.unique_integer([:positive])}"})

    {:ok, view, _} = live(conn, Paths.department(dept.uuid))
    assert has_element?(view, ~s(a[href="#{Paths.new_team(dept.uuid)}"]))

    {:ok, view, _} = live(conn, Paths.new_team(dept.uuid))
    assert has_element?(view, ~s(select option[value="#{dept.uuid}"][selected]))
  end

  test "an unknown department is ignored", %{conn: conn} do
    _dept = fixture_department()

    {:ok, view, _} = live(conn, Paths.new_team(Ecto.UUID.generate()))
    refute has_element?(view, "select option[selected][value]:not([value=''])")
  end
end
