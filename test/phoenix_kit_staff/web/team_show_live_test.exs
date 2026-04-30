defmodule PhoenixKitStaff.Web.TeamShowLiveTest do
  @moduledoc """
  Pins the Phase 2 Batch 1 phx-disable-with delta on the team show
  page's remove-person icon button — it was the only destructive
  `phx-click` site that landed without `phx-disable-with` before this
  sweep.
  """

  use PhoenixKitStaff.LiveCase, async: false

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn}
  end

  describe "remove-person button" do
    test "renders with phx-disable-with after the Phase 2 Batch 1 fix", %{conn: conn} do
      dept = fixture_department()
      team = fixture_team(%{"department_uuid" => dept.uuid})
      person = fixture_person(%{"status" => "active"})
      {:ok, _tm} = PhoenixKitStaff.Staff.add_team_person(team.uuid, person.uuid)

      {:ok, _view, html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

      # The remove button must carry phx-disable-with={gettext("Removing…")}.
      # Match a regex that's tolerant of attribute ordering but pins the
      # phx-click + phx-disable-with pair on the same button.
      assert html =~ ~r/phx-click="remove_person"[\s\S]*?phx-disable-with=/ or
               html =~ ~r/phx-disable-with=[\s\S]*?phx-click="remove_person"/
    end
  end
end
