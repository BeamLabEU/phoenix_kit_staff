defmodule PhoenixKitStaff.Web.SkillShowLiveTest do
  @moduledoc """
  Smoke tests for the skill show page: assign a person to a skill (with a
  proficiency level), remove them, and the failure/empty paths — with
  activity threaded.
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.Skills

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  test "mounts and shows the skill name + empty roster + level picker", %{conn: conn} do
    skill = fixture_skill(%{"name" => "Elixir-#{System.unique_integer([:positive])}"})
    # A person must exist so the add form (and its level picker) renders.
    fixture_person()

    {:ok, _view, html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}")
    assert html =~ skill.name
    assert html =~ "No one has this skill yet."
    # the level picker offers the labels
    assert html =~ "Expert"
  end

  test "add a person at a level logs activity + lists them", %{conn: conn, actor_uuid: actor_uuid} do
    skill = fixture_skill()
    person = fixture_person()

    {:ok, view, _html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}")

    view
    |> form("#skill-add-person-form",
      assign: %{staff_person_uuid: person.uuid, proficiency_level: "expert"}
    )
    |> render_submit()

    assert_activity_logged("staff.person_skill_added",
      resource_uuid: skill.uuid,
      actor_uuid: actor_uuid,
      target_uuid: person.user_uuid
    )

    [ps] = Skills.list_people_for_skill(skill.uuid)
    assert ps.staff_person_uuid == person.uuid
    assert ps.proficiency_level == "expert"
  end

  test "remove a person logs activity + clears them", %{conn: conn, actor_uuid: actor_uuid} do
    skill = fixture_skill()
    person = fixture_person()
    {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, nil)

    {:ok, view, _html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}")
    render_click(view, "remove_person", %{"uuid" => ps.uuid})

    assert_activity_logged("staff.person_skill_removed",
      resource_uuid: skill.uuid,
      actor_uuid: actor_uuid,
      target_uuid: person.user_uuid
    )

    assert Skills.list_people_for_skill(skill.uuid) == []
  end

  test "changing the level updates the assignment", %{conn: conn} do
    skill = fixture_skill()
    person = fixture_person()
    {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, "beginner")

    {:ok, view, _html} = live(conn, "/en/admin/staff/skills/#{skill.uuid}")
    render_change(view, "change_level", %{"uuid" => ps.uuid, "proficiency_level" => "advanced"})

    [updated] = Skills.list_people_for_skill(skill.uuid)
    assert updated.proficiency_level == "advanced"
  end
end
