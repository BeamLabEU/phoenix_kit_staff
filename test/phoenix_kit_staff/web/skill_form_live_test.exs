defmodule PhoenixKitStaff.Web.SkillFormLiveTest do
  @moduledoc """
  Smoke tests for the skill form (mirrors `team_form_live_test.exs`):
  phx-disable-with present, validate sets `:action` so errors render
  inline, save logs activity threading `actor_uuid`, and the failure-side
  `db_pending` audit row is written on a changeset error.
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.Skills

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "new skill form" do
    test "mounts and renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/skills/new")
      assert html =~ "New skill"
      assert html =~ ~r/phx-disable-with=/
    end

    test "validate sets changeset :action so errors render inline", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")

      html = view |> form("#skill-form", skill: %{name: "", description: "x"}) |> render_change()
      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "save creates + logs activity with actor_uuid + resource_uuid", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      name = "Skill-#{System.unique_integer([:positive])}"

      view |> form("#skill-form", skill: %{name: name, description: "x"}) |> render_submit()

      [skill] = Skills.list() |> Enum.filter(&(&1.name == name))

      assert_activity_logged("staff.skill_created",
        resource_uuid: skill.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"name" => name}
      )
    end

    test "create Save with blank name writes a db_pending audit row", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")

      view |> form("#skill-form", skill: %{name: ""}) |> render_submit()

      assert_activity_logged("staff.skill_created",
        actor_uuid: actor_uuid,
        resource_uuid: nil,
        metadata_has: %{"db_pending" => true, "error_kind" => "changeset"}
      )
    end
  end

  describe "edit skill form" do
    test "renders existing values", %{conn: conn} do
      skill = fixture_skill(%{"name" => "Existing-#{System.unique_integer([:positive])}"})
      {:ok, _view, html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}/edit")
      assert html =~ skill.name
      assert html =~ "Edit"
    end

    test "404 for missing uuid redirects with flash", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/skills"}}} =
               live(conn, "/en/admin/staff/skills/#{bogus}/edit")
    end

    test "save updates + logs activity", %{conn: conn, actor_uuid: actor_uuid} do
      skill = fixture_skill(%{"name" => "Old-#{System.unique_integer([:positive])}"})
      new_name = "New-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}/edit")
      view |> form("#skill-form", skill: %{name: new_name}) |> render_submit()

      assert_activity_logged("staff.skill_updated",
        resource_uuid: skill.uuid,
        actor_uuid: actor_uuid
      )

      assert Skills.get!(skill.uuid).name == new_name
    end
  end
end
