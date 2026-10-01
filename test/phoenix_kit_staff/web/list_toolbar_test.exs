defmodule PhoenixKitStaff.Web.ListToolbarTest do
  @moduledoc """
  Every staff list puts its create button on the page, in the table's
  toolbar — never in the admin header — and keeps it there when the list is
  empty. Each empty list says why and offers the way out.
  """
  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.Paths

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "an empty list keeps its create button in the toolbar, and offers the first one",
       %{conn: conn} do
    for {path, new_path, first} <- [
          {Paths.departments(), Paths.new_department(), "Create your first department"},
          {Paths.teams(), Paths.new_team(), "Create your first team"},
          {Paths.skills(), Paths.new_skill(), "Create your first skill"},
          {Paths.people(), Paths.new_person(), "Create your first staff member"}
        ] do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, ~s(a[href="#{new_path}"][aria-label])), path
      assert html =~ first, path
      refute has_element?(view, "#test-page-action"), path
    end
  end

  test "a filter that matches nothing offers to clear it; the trash just says it is empty",
       %{conn: conn} do
    _ = fixture_person()

    {:ok, view, _} = live(conn, Paths.people() <> "?q=nobody-at-all")
    assert render(view) =~ "No staff match."
    assert has_element?(view, "button[phx-click='clear']", "Clear filter")

    {:ok, view, _} = live(conn, Paths.people() <> "?status=trashed")
    assert render(view) =~ "Trash is empty."
    refute render(view) =~ "Clear filter"
  end
end
