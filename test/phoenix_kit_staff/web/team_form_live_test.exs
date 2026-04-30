defmodule PhoenixKitStaff.Web.TeamFormLiveTest do
  @moduledoc """
  Smoke tests for the team form (Batch 4 coverage push — the original
  sweep had 0% coverage on this LV). Mirrors
  `department_form_live_test.exs` shape: phx-disable-with present,
  validate event sets `:action` so `<.input>` renders errors, save
  flashes the rendered HTML, activity logging threads `actor_uuid`.
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.{Schemas, Teams}

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    dept = fixture_department()
    {:ok, conn: conn, actor_uuid: scope.user.uuid, dept: dept}
  end

  describe "new team form" do
    test "mounts and renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/teams/new")
      assert html =~ "New team"
    end

    test "submit button has phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/teams/new")
      assert html =~ ~r/phx-disable-with=/
    end

    test "validate event sets changeset :action so errors render inline", %{
      conn: conn,
      dept: dept
    } do
      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/new")

      html =
        view
        |> form("#team-form",
          team: %{name: "", description: "x", department_uuid: dept.uuid}
        )
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "save logs activity with actor_uuid + resource_uuid threaded", %{
      conn: conn,
      actor_uuid: actor_uuid,
      dept: dept
    } do
      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/new")

      name = "Team-#{System.unique_integer([:positive])}"

      view
      |> form("#team-form",
        team: %{name: name, description: "Eng", department_uuid: dept.uuid}
      )
      |> render_submit()

      [team] =
        Teams.list()
        |> Enum.filter(&(&1.name == name))

      assert_activity_logged("staff.team_created",
        resource_uuid: team.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"name" => name}
      )
    end
  end

  describe "save error — failure-side audit row" do
    test "create-form Save with invalid changeset writes a db_pending audit row", %{
      conn: conn,
      actor_uuid: actor_uuid,
      dept: dept
    } do
      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/new")

      view
      |> form("#team-form",
        team: %{name: "", description: "x", department_uuid: dept.uuid}
      )
      |> render_submit()

      assert_activity_logged("staff.team_created",
        actor_uuid: actor_uuid,
        resource_uuid: nil,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "changeset"
        }
      )
    end

    test "edit-form Save error keeps the original record uuid on the audit row", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      team = fixture_team(%{"name" => "Editable-#{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}/edit")

      view
      |> form("#team-form",
        team: %{name: "", description: team.description, department_uuid: team.department_uuid}
      )
      |> render_submit()

      assert_activity_logged("staff.team_updated",
        actor_uuid: actor_uuid,
        resource_uuid: team.uuid,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "changeset"
        }
      )
    end
  end

  describe "edit team form" do
    test "renders existing values", %{conn: conn} do
      team = fixture_team(%{"name" => "Existing-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/teams/#{team.uuid}/edit")
      assert html =~ team.name
      assert html =~ "Edit"
    end

    test "404 for missing uuid redirects with flash", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/teams"}}} =
               live(conn, "/en/admin/staff/teams/#{bogus}/edit")
    end

    test "save updates and logs activity with actor_uuid threaded", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      team = fixture_team(%{"name" => "OldName-#{System.unique_integer([:positive])}"})
      new_name = "Renamed-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}/edit")

      view
      |> form("#team-form",
        team: %{
          name: new_name,
          description: team.description,
          department_uuid: team.department_uuid
        }
      )
      |> render_submit()

      assert_activity_logged("staff.team_updated",
        resource_uuid: team.uuid,
        actor_uuid: actor_uuid
      )

      assert Teams.get!(team.uuid).name == new_name
    end
  end

  describe "schema typespec / changeset shape" do
    test "Team.changeset/2 returns Ecto.Changeset.t(t())", %{dept: dept} do
      cs =
        Schemas.Team.changeset(%Schemas.Team{}, %{name: "x", department_uuid: dept.uuid})

      assert %Ecto.Changeset{data: %Schemas.Team{}} = cs
      assert cs.valid?
    end

    test "name length validation rejects > 255 chars", %{conn: conn, dept: dept} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/new")

      long_name = String.duplicate("x", 256)

      html =
        view
        |> form("#team-form",
          team: %{name: long_name, department_uuid: dept.uuid}
        )
        |> render_change()

      assert html =~ "should be at most 255"
    end
  end
end
