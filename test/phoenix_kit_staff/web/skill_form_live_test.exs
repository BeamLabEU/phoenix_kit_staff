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

  describe "levels editor (selectors)" do
    # Selector/option inputs carry generated ids in their names:
    # `group[<gid>][name]` and `option[<oid>][name]`.
    defp group_ids(html), do: scan_ids(html, ~r/group\[([0-9a-f]+)\]\[name\]/)
    defp option_ids(html), do: scan_ids(html, ~r/option\[([0-9a-f]+)\]\[name\]/)

    defp scan_ids(html, re),
      do: re |> Regex.scan(html) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

    test "seed standard levels + save persists one selector with its options (et translations)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      name = "Seeded-#{System.unique_integer([:positive])}"

      render_click(view, "seed_standard_levels")
      assert render(view) =~ "Beginner"

      view |> form("#skill-form", skill: %{name: name}) |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == name))
      assert [selector] = skill.levels
      assert selector["name"] == "Proficiency"

      assert Enum.map(selector["options"], & &1["name"]) ==
               ["Beginner", "Intermediate", "Advanced", "Expert"]

      # seed pre-fills et translations on the selector and its options
      assert selector["translations"]["et"] == "Oskustase"
      assert hd(selector["options"])["translations"]["et"] == "Algaja"
    end

    test "add a selector + a custom option, name it, and save persists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      sname = "Custom-#{System.unique_integer([:positive])}"

      html = render_click(view, "add_selector")
      [gid] = group_ids(html)

      html = render_click(view, "add_option", %{"group-id" => gid})
      [oid] = option_ids(html)

      view
      |> form("#skill-form", %{
        "skill" => %{"name" => sname},
        "group" => %{gid => %{"name" => "Rank"}},
        "option" => %{oid => %{"name" => "Cadet"}}
      })
      |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == sname))
      assert [%{"name" => "Rank", "options" => [%{"name" => "Cadet"}]}] = skill.levels
    end

    test "remove a seeded option before saving drops it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      sname = "Trimmed-#{System.unique_integer([:positive])}"

      html = render_click(view, "seed_standard_levels")
      [gid] = group_ids(html)
      [first_oid | _] = option_ids(html)
      render_click(view, "remove_option", %{"group-id" => gid, "option-id" => first_oid})

      view |> form("#skill-form", skill: %{name: sname}) |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == sname))
      [selector] = skill.levels
      assert Enum.map(selector["options"], & &1["name"]) == ["Intermediate", "Advanced", "Expert"]
    end

    test "remove a whole selector before saving drops it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      sname = "Dropped-#{System.unique_integer([:positive])}"

      html = render_click(view, "seed_standard_levels")
      [gid] = group_ids(html)
      render_click(view, "remove_selector", %{"group-id" => gid})

      view |> form("#skill-form", skill: %{name: sname}) |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == sname))
      assert skill.levels == []
    end

    test "selector + option name inputs are language-keyed so a switch refreshes the value",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      html = render_click(view, "seed_standard_levels")
      [gid] = group_ids(html)
      [oid | _] = option_ids(html)

      # The input ids carry the active language: morphdom replaces the node on
      # switch_language so the value refreshes to that language's text.
      assert html =~ ~s(id="selector-#{gid}-name-)
      assert html =~ ~s(id="option-#{oid}-name-)
      # On the primary tab the primary names show (et overrides sit in the
      # selector/option translations until the et tab is active).
      assert html =~ "Beginner"
    end

    test "toggling a selector to multiple + save persists allow_multiple", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      sname = "Multi-#{System.unique_integer([:positive])}"

      html = render_click(view, "seed_standard_levels")
      [gid] = group_ids(html)
      render_click(view, "toggle_selector_multiple", %{"group-id" => gid})

      view |> form("#skill-form", skill: %{name: sname}) |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == sname))
      assert [%{"allow_multiple" => true}] = skill.levels
    end

    test "reorder_options (drag-drop) persists the new option order within a selector",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      sname = "OptOrder-#{System.unique_integer([:positive])}"

      html = render_click(view, "seed_standard_levels")
      [_gid] = group_ids(html)
      [a, b, c, d] = option_ids(html)

      # The SortableGrid hook pushes the dropped order as `ordered_ids`; the
      # handler locates the owning selector by its option-id set.
      render_click(view, "reorder_options", %{"ordered_ids" => [d, a, b, c]})

      view |> form("#skill-form", skill: %{name: sname}) |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == sname))
      [selector] = skill.levels

      assert Enum.map(selector["options"], & &1["name"]) ==
               ["Expert", "Beginner", "Intermediate", "Advanced"]
    end

    test "reorder_selectors (drag-drop) persists the new selector order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/skills/new")
      sname = "SelOrder-#{System.unique_integer([:positive])}"

      render_click(view, "add_selector")
      html = render_click(view, "add_selector")
      [g1, g2] = group_ids(html)

      render_click(view, "reorder_selectors", %{"ordered_ids" => [g2, g1]})

      view
      |> form("#skill-form", %{
        "skill" => %{"name" => sname},
        "group" => %{g1 => %{"name" => "Alpha"}, g2 => %{"name" => "Beta"}}
      })
      |> render_submit()

      [skill] = Enum.filter(Skills.list(), &(&1.name == sname))
      # Reordered to [g2, g1] before save → Beta precedes Alpha. (Named
      # selectors with no options are kept by normalization.)
      assert Enum.map(skill.levels, & &1["name"]) == ["Beta", "Alpha"]
    end
  end
end
