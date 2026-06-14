defmodule PhoenixKitStaff.Integration.PersonSkillsTest do
  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.{Skills, Staff}

  describe "assign_skill/3" do
    test "assigns at a level" do
      person = fixture_person()
      skill = fixture_skill()
      assert {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, "expert")
      assert ps.proficiency_level == "expert"
    end

    test "assigns with no level (nil = not set)" do
      person = fixture_person()
      skill = fixture_skill()
      assert {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, nil)
      assert ps.proficiency_level == nil
    end

    test "rejects a duplicate (same person + skill)" do
      person = fixture_person()
      skill = fixture_skill()
      assert {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, nil)
      assert {:error, cs} = Skills.assign_skill(person.uuid, skill.uuid, "beginner")
      # unique index maps onto the first field in the pair
      assert :staff_person_uuid in Keyword.keys(cs.errors)
    end
  end

  describe "update_assignment_level/2" do
    test "changes and clears the level" do
      person = fixture_person()
      skill = fixture_skill()
      {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, "beginner")

      assert {:ok, up} = Skills.update_assignment_level(ps, "advanced")
      assert up.proficiency_level == "advanced"

      assert {:ok, cleared} = Skills.update_assignment_level(up, "")
      assert cleared.proficiency_level == nil
    end
  end

  describe "unassign_skill" do
    test "by struct and by (person, skill); not_found otherwise" do
      person = fixture_person()
      skill = fixture_skill()
      {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, nil)

      assert {:ok, _} = Skills.unassign_skill(ps)
      assert Skills.list_for_person(person.uuid) == []

      {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, nil)
      assert {:ok, _} = Skills.unassign_skill(person.uuid, skill.uuid)
      assert {:error, :not_found} = Skills.unassign_skill(person.uuid, skill.uuid)
    end
  end

  describe "rosters (both directions)" do
    test "list_for_person preloads skill, ordered by name" do
      person = fixture_person()
      z = fixture_skill(%{"name" => "Zed"})
      a = fixture_skill(%{"name" => "Alpha"})
      {:ok, _} = Skills.assign_skill(person.uuid, z.uuid, nil)
      {:ok, _} = Skills.assign_skill(person.uuid, a.uuid, nil)

      names = Skills.list_for_person(person.uuid) |> Enum.map(& &1.skill.name)
      assert names == ["Alpha", "Zed"]
    end

    test "list_people_for_skill excludes trashed people" do
      skill = fixture_skill()
      kept = fixture_person()
      gone = fixture_person()
      {:ok, _} = Skills.assign_skill(kept.uuid, skill.uuid, nil)
      {:ok, _} = Skills.assign_skill(gone.uuid, skill.uuid, nil)
      {:ok, _} = Staff.trash_person(gone)

      people = Skills.list_people_for_skill(skill.uuid) |> Enum.map(& &1.staff_person.uuid)
      assert kept.uuid in people
      refute gone.uuid in people
    end

    test "people_without_skill excludes the already-assigned and the trashed" do
      skill = fixture_skill()
      has = fixture_person()
      without = fixture_person()
      trashed = fixture_person()
      {:ok, _} = Skills.assign_skill(has.uuid, skill.uuid, nil)
      {:ok, _} = Staff.trash_person(trashed)

      uuids = Skills.people_without_skill(skill.uuid) |> Enum.map(& &1.uuid)
      assert without.uuid in uuids
      refute has.uuid in uuids
      refute trashed.uuid in uuids
    end

    test "skills_not_assigned_to excludes already-assigned skills" do
      person = fixture_person()
      assigned = fixture_skill()
      free = fixture_skill()
      {:ok, _} = Skills.assign_skill(person.uuid, assigned.uuid, nil)

      uuids = Skills.skills_not_assigned_to(person.uuid) |> Enum.map(& &1.uuid)
      assert free.uuid in uuids
      refute assigned.uuid in uuids
    end
  end
end
