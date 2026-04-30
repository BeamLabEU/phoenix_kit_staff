defmodule PhoenixKitStaff.Web.HandleInfoCatchallTest do
  @moduledoc """
  Pins the Batch 2 delta: every admin LV's catch-all `handle_info/2`
  clause logs at `Logger.debug` (per the workspace-sync precedent) so
  unexpected PubSub broadcasts surface in dev/test logs instead of
  failing silently.

  The test config sets `config :logger, level: :warning` to keep test
  output clean. `:debug` messages get filtered BEFORE `capture_log`
  sees them — `[level: :debug]` on the handler is not enough. Each
  test lifts `Logger.configure(level: :debug)` for its duration,
  reset on exit. (entities-Batch-3 / publishing-Batch-5 trap.)
  """

  use PhoenixKitStaff.LiveCase, async: false

  import ExUnit.CaptureLog

  setup %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())

    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    {:ok, conn: conn}
  end

  test "OverviewLive logs Logger.debug on unexpected handle_info", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/staff/")

    log =
      capture_log([level: :debug], fn ->
        send(view.pid, :unexpected_message_for_overview)
        :sys.get_state(view.pid)
      end)

    assert log =~ "OverviewLive: unexpected handle_info"
  end

  test "DepartmentsLive logs Logger.debug on unexpected handle_info", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/staff/departments")

    log =
      capture_log([level: :debug], fn ->
        send(view.pid, :unexpected_message_for_departments)
        :sys.get_state(view.pid)
      end)

    assert log =~ "DepartmentsLive: unexpected handle_info"
  end

  test "TeamsLive logs Logger.debug on unexpected handle_info", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/staff/teams")

    log =
      capture_log([level: :debug], fn ->
        send(view.pid, :unexpected_message_for_teams)
        :sys.get_state(view.pid)
      end)

    assert log =~ "TeamsLive: unexpected handle_info"
  end

  test "PeopleLive logs Logger.debug on unexpected handle_info", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/staff/people")

    log =
      capture_log([level: :debug], fn ->
        send(view.pid, :unexpected_message_for_people)
        :sys.get_state(view.pid)
      end)

    assert log =~ "PeopleLive: unexpected handle_info"
  end

  test "DepartmentShowLive logs Logger.debug on unexpected handle_info", %{conn: conn} do
    dept = fixture_department()

    {:ok, view, _html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}")

    log =
      capture_log([level: :debug], fn ->
        send(view.pid, :unexpected_message_for_dept_show)
        :sys.get_state(view.pid)
      end)

    assert log =~ "DepartmentShowLive: unexpected handle_info"
  end

  test "TeamShowLive logs Logger.debug on unexpected handle_info", %{conn: conn} do
    team = fixture_team()

    {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

    log =
      capture_log([level: :debug], fn ->
        send(view.pid, :unexpected_message_for_team_show)
        :sys.get_state(view.pid)
      end)

    assert log =~ "TeamShowLive: unexpected handle_info"
  end

  test "PersonShowLive logs Logger.debug on unexpected handle_info", %{conn: conn} do
    person = fixture_person()

    {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

    log =
      capture_log([level: :debug], fn ->
        send(view.pid, :unexpected_message_for_person_show)
        :sys.get_state(view.pid)
      end)

    assert log =~ "PersonShowLive: unexpected handle_info"
  end
end
