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

    test "edit round-trips existing level names", %{conn: conn} do
      {skill, _ids} = fixture_skill_with_levels(["Bronze", "Silver", "Gold"])
      {:ok, _view, html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}/edit")

      assert html =~ "Bronze"
      assert html =~ "Silver"
      assert html =~ "Gold"
    end
  end

  describe "levels editor" do
    # The level inputs carry a generated id in their name: `level[<id>][name]`.
    defp level_ids(html) do
      ~r/level\[([0-9a-f]+)\]\[name\]/
      |> Regex.scan(html)
      |> Enum.map(&Enum.at(&1, 1))
      |> Enum.uniq()
    end

    test "seed standard levels + save persists them (with et translations)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      name = "Seeded-#{System.unique_integer([:positive])}"

      render_click(view, "seed_standard_levels")
      # the seeded names render in the editor
      assert render(view) =~ "Beginner"

      view |> form("#skill-form", skill: %{name: name}) |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == name))
      names = Enum.map(skill.levels, & &1["name"])
      assert names == ["Beginner", "Intermediate", "Advanced", "Expert"]
      # seed pre-fills et translations
      assert hd(skill.levels)["translations"]["et"] == "Algaja"
    end

    test "add a custom level, name it, and save persists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      sname = "Custom-#{System.unique_integer([:positive])}"
      lname = "Cadet"

      html = render_click(view, "add_level")
      [id] = level_ids(html)

      view
      |> form("#skill-form", %{
        "skill" => %{"name" => sname},
        "level" => %{id => %{"name" => lname}}
      })
      |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == sname))
      assert [%{"name" => "Cadet"}] = skill.levels
    end

    test "remove a seeded level before saving drops it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      sname = "Trimmed-#{System.unique_integer([:positive])}"

      html = render_click(view, "seed_standard_levels")
      [first_id | _] = level_ids(html)
      render_click(view, "remove_level", %{"id" => first_id})

      view |> form("#skill-form", skill: %{name: sname}) |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == sname))
      names = Enum.map(skill.levels, & &1["name"])
      assert names == ["Intermediate", "Advanced", "Expert"]
    end

    test "level-name inputs are language-keyed so a switch refreshes the value", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      html = render_click(view, "seed_standard_levels")
      [id | _] = level_ids(html)

      # The input id carries the active language (H2): morphdom replaces the
      # node on switch_language so the value refreshes to that language's text.
      assert html =~ ~s(id="level-#{id}-name-)
      # On the primary tab the primary name shows (the et override sits in the
      # level's translations until the et tab is active).
      assert html =~ "Beginner"
    end

    test "toggling allow-multiple + save persists the flag", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      sname = "Multi-#{System.unique_integer([:positive])}"

      render_submit(view, "save", %{
        "skill" => %{"name" => sname, "allow_multiple_levels" => "true"}
      })

      [skill] = Enum.filter(Skills.list(), &(&1.name == sname))
      assert skill.allow_multiple_levels == true
    end
  end
end
