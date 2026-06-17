defmodule PhoenixKitStaff.Web.PersonMediaComponentTest do
  @moduledoc """
  Smoke tests for the Files / Images tabs on the person profile.

  The attach/remove/avatar mutation paths are pinned at the context layer
  (`Attachments` + the soft-delete create-path guard in
  `integration/soft_delete_test.exs`); these cover the component's render +
  tab wiring, which previously had no test file at all. Storage is an
  always-enabled core module, so the tabs render; with no folder seeded the
  file list is empty and the empty-state copy shows.
  """
  use PhoenixKitStaff.LiveCase, async: false

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp open_tab(conn, person, tab) do
    {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")
    render_click(view, "switch_tab", %{"tab" => tab})
    view
  end

  test "the Files tab renders its heading, Add button, and empty state", %{conn: conn} do
    html = render(open_tab(conn, fixture_person(), "files"))

    assert html =~ "Files"
    assert html =~ "Add files"
    assert html =~ "No files yet."
  end

  test "the Images tab renders its heading, Add button, and empty state", %{conn: conn} do
    html = render(open_tab(conn, fixture_person(), "images"))

    assert html =~ "Images"
    assert html =~ "Add images"
    assert html =~ "No images yet."
  end
end
