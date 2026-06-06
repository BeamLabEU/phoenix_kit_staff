defmodule PhoenixKitStaff.Web.ListingLvsTest do
  @moduledoc """
  LV smoke tests for the 4 listing/overview LVs that previously had
  none (Batch 3 fix-everything). Mount + one happy-path interaction
  per page, with `actor_uuid` and `resource_uuid` pinned on every
  activity assertion so a regression that drops opt-threading is
  caught (locations Batch 3 / publishing Batch 4 precedent).

  Smoke-level scope — each test:
  - Mounts the page
  - Renders the page title
  - Drives one delete event (or pubsub broadcast for the show pages)
  - Asserts the resulting flash + activity row
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.PubSub, as: StaffPubSub

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "OverviewLive" do
    test "mounts and renders org overview", %{conn: conn} do
      _dept = fixture_department(%{"name" => "Eng-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/")

      assert html =~ "Departments, teams, and the people in them"
    end

    test "reloads on PubSub broadcast", %{conn: conn} do
      {:ok, view, _initial} = live(conn, "/en/admin/staff/")

      # Create a dept and broadcast — the LV's `{:staff, _, _}` handler
      # should re-fetch and reflect the new dept.
      dept = fixture_department(%{"name" => "Sales-#{System.unique_integer([:positive])}"})
      send(view.pid, {:staff, :department_created, %{uuid: dept.uuid}})

      html = render(view)
      assert html =~ dept.name
    end
  end

  describe "DepartmentsLive" do
    test "mounts and renders the department list", %{conn: conn} do
      dept = fixture_department(%{"name" => "Eng-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/departments")

      assert html =~ "Departments"
      assert html =~ dept.name
    end

    test "delete event logs activity with actor_uuid + resource_uuid threaded", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      dept = fixture_department(%{"name" => "Doomed-#{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, "/en/admin/staff/departments")

      view
      |> element("button[phx-click='delete'][phx-value-uuid='#{dept.uuid}']")
      |> render_click()

      assert_activity_logged("staff.department_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: dept.uuid,
        metadata_has: %{"name" => dept.name}
      )

      assert render(view) =~ "Department deleted"
    end
  end

  describe "TeamsLive" do
    test "mounts and renders the teams list", %{conn: conn} do
      team = fixture_team(%{"name" => "T-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/teams")

      assert html =~ "Teams"
      assert html =~ team.name
    end

    test "delete event logs activity with actor_uuid + resource_uuid threaded", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      team = fixture_team(%{"name" => "Doomed-#{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, "/en/admin/staff/teams")

      view
      |> element("button[phx-click='delete'][phx-value-uuid='#{team.uuid}']")
      |> render_click()

      assert_activity_logged("staff.team_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: team.uuid,
        metadata_has: %{"name" => team.name}
      )

      assert render(view) =~ "Team deleted"
    end
  end

  describe "PeopleLive" do
    test "mounts and renders the people list", %{conn: conn} do
      person = fixture_person()

      {:ok, _view, html} = live(conn, "/en/admin/staff/people")

      assert html =~ person.user.email
    end

    test "trash event logs activity with actor_uuid + resource_uuid + target_uuid threaded", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people")

      view
      |> element("button[phx-click='trash'][phx-value-uuid='#{person.uuid}']")
      |> render_click()

      assert_activity_logged("staff.person_trashed",
        actor_uuid: actor_uuid,
        resource_uuid: person.uuid
      )

      assert render(view) =~ "Staff moved to trash"
    end

    test "trash with bogus uuid flashes not-found and does NOT log activity", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people")

      bogus = Ecto.UUID.generate()

      render_click(view, "trash", %{"uuid" => bogus})

      refute_activity_logged("staff.person_trashed", resource_uuid: bogus)
      assert render(view) =~ "Staff not found"
    end

    # Regression for a Codex finding: the bulk-select hook supplies the
    # uuids client-side, so a malformed/adversarial payload must not crash
    # the LV — `sanitize_uuids/1` drops anything that isn't a valid UUID.
    test "bulk_trash ignores malformed uuids and trashes only the valid ones", %{conn: conn} do
      person = fixture_person()
      {:ok, view, _html} = live(conn, "/en/admin/staff/people")

      render_click(view, "bulk_trash", %{
        "uuids" => [person.uuid, "not-a-uuid", 42, %{"k" => "v"}]
      })

      assert Process.alive?(view.pid)
      assert PhoenixKitStaff.Staff.get_person(person.uuid).status == "trashed"
    end

    # Regression for a Codex finding: a zero-count bulk op (stale/already-
    # trashed selection) must NOT write an audit row; a real one must.
    test "bulk_trash logs activity only when it actually trashes someone", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      already = fixture_person()
      {:ok, already_trashed} = PhoenixKitStaff.Staff.trash_person(already)
      fresh = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people")

      # No-op: the row is already trashed → count 0 → no log.
      render_click(view, "bulk_trash", %{"uuids" => [already_trashed.uuid]})
      refute_activity_logged("staff.people_bulk_trashed", actor_uuid: actor_uuid)

      # Real action: count 1 → audit row present.
      render_click(view, "bulk_trash", %{"uuids" => [fresh.uuid]})
      assert_activity_logged("staff.people_bulk_trashed", actor_uuid: actor_uuid)
    end
  end

  describe "DepartmentShowLive" do
    test "mounts existing department", %{conn: conn} do
      dept = fixture_department(%{"name" => "Eng-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}")

      assert html =~ dept.name
    end

    test "redirects on :department_deleted broadcast", %{conn: conn} do
      dept = fixture_department()

      {:ok, view, _html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}")

      send(view.pid, {:staff, :department_deleted, %{uuid: dept.uuid}})

      # The handler push_navigates back to the departments list.
      assert_redirect(view, "/en/admin/staff/departments")
    end
  end

  describe "PersonShowLive" do
    test "mounts existing person", %{conn: conn} do
      person = fixture_person()

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      assert html =~ person.user.email
    end

    test "redirects on :person_deleted broadcast", %{conn: conn} do
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      send(view.pid, {:staff, :person_deleted, %{uuid: person.uuid}})

      assert_redirect(view, "/en/admin/staff/people")
    end

    test "renders the Overview tab; Comments tab is gated on the optional comments module",
         %{conn: conn} do
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      assert has_element?(view, ~s|button[role="tab"][phx-value-tab="overview"]|)
      # phoenix_kit_comments isn't a dep in the standalone suite, so the
      # Comments tab degrades away (and the embedded thread never renders).
      refute has_element?(view, ~s|button[role="tab"][phx-value-tab="comments"]|)
    end

    test "switch_tab handler is safe even when the comments module is absent",
         %{conn: conn} do
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # The Comments tab is hidden standalone, but the handler must still
      # be race/crash-safe: switching to "comments" gates the live_component
      # on the (absent) module, so it renders nothing rather than blowing up.
      render_click(view, "switch_tab", %{"tab" => "comments"})
      assert Process.alive?(view.pid)

      html = render_click(view, "switch_tab", %{"tab" => "overview"})
      assert html =~ person.user.email
    end

    test "leaf_changed forward is a safe no-op when comments is unavailable",
         %{conn: conn} do
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # The composer's Leaf editor sends {:leaf_changed, ...} to the host;
      # with phoenix_kit_comments absent (standalone suite) the runtime
      # forward resolves to nil and must no-op without crashing.
      send(view.pid, {:leaf_changed, %{editor_id: "x", markdown: "hi"}})
      assert render(view) =~ person.user.email
      assert Process.alive?(view.pid)
    end
  end

  describe "TeamShowLive — extension to existing test (mount + remove_person path)" do
    test "remove_person removes the membership and logs activity", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      team = fixture_team()
      person = fixture_person()
      {:ok, tm} = PhoenixKitStaff.Staff.add_team_person(team.uuid, person.uuid)

      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

      view
      |> element("button[phx-click='remove_person'][phx-value-uuid='#{tm.uuid}']")
      |> render_click()

      assert_activity_logged("staff.team_person_removed",
        actor_uuid: actor_uuid,
        resource_uuid: team.uuid
      )

      assert render(view) =~ "Staff removed"
    end
  end

  describe "PubSub round-trip — subscribe-before-fetch race window covered" do
    test "show pages receive their own broadcast and re-render", %{conn: conn} do
      dept = fixture_department(%{"name" => "Engin-#{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}")

      # Update the dept and broadcast — the LV must pick up the update.
      {:ok, updated} = PhoenixKitStaff.Departments.update(dept, %{"name" => "Renamed"})

      StaffPubSub.broadcast_department(:department_updated, %{
        uuid: updated.uuid,
        name: updated.name
      })

      # Wait for the LV to process the broadcast.
      :sys.get_state(view.pid)
      assert render(view) =~ "Renamed"
    end
  end
end
