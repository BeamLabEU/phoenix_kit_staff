defmodule PhoenixKitStaff.Web.ErrorBranchLoggingTest do
  @moduledoc """
  Pins that destructive admin LV `:error` branches route through
  `PhoenixKitStaff.Web.Helpers.log_operation_error/3` (Batch 3
  fix-everything pass).

  Two flavours of test here:

  1. **LV-driven reachable error path** — `team_show_live#add_person`
     with a duplicate add triggers `assoc_constraint`/`unique_constraint`
     on `TeamMembership.changeset/2` and returns `{:error, %Ecto.Changeset{}}`
     to the LV's `:error` branch. We drive the form via
     `Phoenix.LiveViewTest.render_submit/2` and assert the activity
     row lands.

  2. **Source-pairing structural pin** for unreachable defense-in-depth
     branches — Department/Team/Person delete contexts use
     `on_delete: :delete_all` cascades, so the underlying
     `Repo.delete/1` always succeeds for valid records. The `:error`
     branch in the LV is defensive (e.g. for future schema changes
     adding constraints). The test asserts source-paired
     `Helpers.log_operation_error(...)` calls in those branches —
     same shape as `subscribe_before_fetch_test.exs`. Catalogue
     Batch 4 / locations Batch 3a precedent.
  """

  use PhoenixKitStaff.LiveCase, async: false

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "LV-driven reachable error path — team_show#add_person duplicate" do
    test "logs failure-side activity row with db_pending=true on duplicate add", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      team = fixture_team()
      person_a = fixture_person()
      _person_b = fixture_person()

      # First add succeeds.
      {:ok, _tm} = PhoenixKitStaff.Staff.add_team_person(team.uuid, person_a.uuid)

      # Mount the LV. The dropdown filters out person_a (already on team),
      # but we can drive the `add_person` event directly with person_a's
      # uuid to simulate a stale-form-submit race. Result:
      # `unique_constraint([:team_uuid, :staff_person_uuid])` fires →
      # {:error, %Ecto.Changeset{}} → LV's :error branch logs.
      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

      render_submit(view, "add_person", %{"staff_person_uuid" => person_a.uuid})

      assert_activity_logged("staff.team_person_added",
        actor_uuid: actor_uuid,
        resource_uuid: team.uuid,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "changeset"
        }
      )
    end
  end

  describe "Source-pairing structural pin for unreachable defense-in-depth branches" do
    @lv_branches [
      {"people_live.ex", "delete_person", "staff.person_deleted"},
      {"departments_live.ex", "Departments.delete", "staff.department_deleted"},
      {"teams_live.ex", "Teams.delete", "staff.team_deleted"},
      {"team_show_live.ex", "remove_team_person", "staff.team_person_removed"}
    ]

    for {file, fn_call, action_atom} <- @lv_branches do
      test "#{file} :error branch wires #{fn_call} to log_operation_error(#{action_atom})" do
        path =
          Path.join([
            File.cwd!(),
            "lib",
            "phoenix_kit_staff",
            "web",
            unquote(file)
          ])

        source = File.read!(path)

        assert source =~ "Helpers.log_operation_error(\"#{unquote(action_atom)}\"",
               """
               Expected #{unquote(file)} to call
               `Helpers.log_operation_error("#{unquote(action_atom)}", ...)` in
               the `#{unquote(fn_call)}` :error branch — the catalogue Batch 4
               canonical pattern for failure-side audit rows. Without this,
               an :error return from #{unquote(fn_call)} (after a future
               schema change adds a constraint, or a race) would silently
               erase the user's intent from the activity feed.
               """
      end
    end
  end
end
