defmodule PhoenixKitStaff.Web.SkillShowLiveTest do
  @moduledoc """
  Smoke tests for the skill show page: assign a person to a skill (at the
  skill's own levels), change/remove, and the empty paths — activity threaded.
  Level selection is event-driven toggle chips (`toggle_add_level` on the add
  form, `toggle_level` on the roster), so there's no `proficiency_level` form
  field anymore.
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.Skills

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  test "mounts and shows the skill name + empty roster + level chips", %{conn: conn} do
    {skill, _ids} =
      fixture_skill_with_levels(["Expert"], %{
        "name" => "Elixir-#{System.unique_integer([:positive])}"
      })

    # A person must exist so the add form (and its level chips) renders.
    fixture_person()

    {:ok, _view, html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}")
    assert html =~ skill.name
    assert html =~ "No one has this skill yet."
    # the level chips offer the skill's own level
    assert html =~ "Expert"
  end

  test "add a person at a level logs activity + lists them", %{conn: conn, actor_uuid: actor_uuid} do
    {skill, ids} = fixture_skill_with_levels(["Expert"])
    person = fixture_person()

    {:ok, view, _html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}")

    # toggle the "Expert" chip, then submit the person
    render_click(view, "toggle_add_level", %{"id" => ids["Expert"]})

    view
    |> form("#skill-add-person-form", assign: %{staff_person_uuid: person.uuid})
    |> render_submit()

    assert_activity_logged("staff.person_skill_added",
      resource_uuid: skill.uuid,
      actor_uuid: actor_uuid,
      target_uuid: person.user_uuid
    )

    [ps] = Skills.list_people_for_skill(skill.uuid)
    assert ps.staff_person_uuid == person.uuid
    assert ps.proficiency_levels == [ids["Expert"]]
  end

  test "remove a person logs activity + clears them", %{conn: conn, actor_uuid: actor_uuid} do
    skill = fixture_skill()
    person = fixture_person()
    {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, [])

    {:ok, view, _html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}")
    render_click(view, "remove_person", %{"uuid" => ps.uuid})

    assert_activity_logged("staff.person_skill_removed",
      resource_uuid: skill.uuid,
      actor_uuid: actor_uuid,
      target_uuid: person.user_uuid
    )

    assert Skills.list_people_for_skill(skill.uuid) == []
  end

  test "toggling a roster chip updates the assignment", %{conn: conn} do
    {skill, ids} = fixture_skill_with_levels(["Beginner", "Advanced"])
    person = fixture_person()
    {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, [ids["Beginner"]])

    {:ok, view, _html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}")
    # single-select: toggling "Advanced" replaces "Beginner"
    render_click(view, "toggle_level", %{"uuid" => ps.uuid, "id" => ids["Advanced"]})

    [updated] = Skills.list_people_for_skill(skill.uuid)
    assert updated.proficiency_levels == [ids["Advanced"]]
  end

  test "multi-select skill keeps several roster chips", %{conn: conn} do
    {skill, ids} = fixture_skill_with_levels(["B", "C", "D"], %{"allow_multiple_levels" => true})
    person = fixture_person()
    {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, [ids["B"]])

    {:ok, view, _html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}")
    render_click(view, "toggle_level", %{"uuid" => ps.uuid, "id" => ids["C"]})

    [updated] = Skills.list_people_for_skill(skill.uuid)
    assert updated.proficiency_levels == [ids["B"], ids["C"]]
  end
end
