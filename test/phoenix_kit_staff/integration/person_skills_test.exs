defmodule PhoenixKitStaff.Integration.PersonSkillsTest do
  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.{Skills, Staff}

  describe "assign_skill/3" do
    test "assigns at a level (single-select)" do
      person = fixture_person()
      {skill, ids} = fixture_skill_with_levels(["Beginner", "Expert"])

      assert {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, [ids["Expert"]])
      assert ps.proficiency_levels == [ids["Expert"]]
    end

    test "assigns with no level ([] = not set)" do
      person = fixture_person()
      skill = fixture_skill()
      assert {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, [])
      assert ps.proficiency_levels == []
    end

    test "assigns several levels when the skill allows multiple" do
      person = fixture_person()

      {skill, ids} =
        fixture_skill_with_levels(["B", "C", "D"], %{"allow_multiple_levels" => true})

      assert {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, [ids["C"], ids["B"]])
      # normalized to skill-levels order
      assert ps.proficiency_levels == [ids["B"], ids["C"]]
    end

    test "rejects more than one level on a single-select skill" do
      person = fixture_person()
      {skill, ids} = fixture_skill_with_levels(["B", "C"])

      assert {:error, :too_many_levels} =
               Skills.assign_skill(person.uuid, skill.uuid, [ids["B"], ids["C"]])
    end

    test "rejects an unknown level id" do
      person = fixture_person()
      skill = fixture_skill()
      assert {:error, :invalid_levels} = Skills.assign_skill(person.uuid, skill.uuid, ["ghost"])
    end

    test "rejects non-binary level ids without crashing" do
      person = fixture_person()
      {skill, _ids} = fixture_skill_with_levels(["B"])

      assert {:error, :invalid_levels} =
               Skills.assign_skill(person.uuid, skill.uuid, [%{"x" => 1}])
    end

    test "rejects a missing skill" do
      person = fixture_person()

      assert {:error, :skill_not_found} =
               Skills.assign_skill(person.uuid, Ecto.UUID.generate(), [])
    end

    test "rejects a duplicate (same person + skill)" do
      person = fixture_person()
      skill = fixture_skill()
      assert {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, [])
      assert {:error, cs} = Skills.assign_skill(person.uuid, skill.uuid, [])
      assert :staff_person_uuid in Keyword.keys(cs.errors)
    end
  end

  describe "update_assignment_levels/2" do
    test "changes and clears the levels" do
      person = fixture_person()
      {skill, ids} = fixture_skill_with_levels(["Beginner", "Advanced"])
      {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, [ids["Beginner"]])

      assert {:ok, up} = Skills.update_assignment_levels(ps, [ids["Advanced"]])
      assert up.proficiency_levels == [ids["Advanced"]]

      assert {:ok, cleared} = Skills.update_assignment_levels(up, [])
      assert cleared.proficiency_levels == []
    end
  end

  describe "unassign_skill" do
    test "by struct and by (person, skill); not_found otherwise" do
      person = fixture_person()
      skill = fixture_skill()
      {:ok, ps} = Skills.assign_skill(person.uuid, skill.uuid, [])

      assert {:ok, _} = Skills.unassign_skill(ps)
      assert Skills.list_for_person(person.uuid) == []

      {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, [])
      assert {:ok, _} = Skills.unassign_skill(person.uuid, skill.uuid)
      assert {:error, :not_found} = Skills.unassign_skill(person.uuid, skill.uuid)
    end
  end

  describe "Skills.update/2 reconciles assignments" do
    test "strips a removed level id from existing assignments" do
      person = fixture_person()
      {skill, ids} = fixture_skill_with_levels(["B", "C"], %{"allow_multiple_levels" => true})
      {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, [ids["B"], ids["C"]])

      # drop level "C" from the skill
      kept_level = Enum.find(skill.levels, &(&1["id"] == ids["B"]))
      {:ok, _} = Skills.update(skill, %{"levels" => [kept_level]})

      assert [ps] = Skills.list_for_person(person.uuid)
      assert ps.proficiency_levels == [ids["B"]]
    end

    test "prunes assignments to one level when toggled multiple→single" do
      person = fixture_person()
      {skill, ids} = fixture_skill_with_levels(["B", "C"], %{"allow_multiple_levels" => true})
      {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, [ids["B"], ids["C"]])

      {:ok, _} = Skills.update(skill, %{"allow_multiple_levels" => false})

      assert [ps] = Skills.list_for_person(person.uuid)
      # kept the first in skill order
      assert ps.proficiency_levels == [ids["B"]]
    end
  end

  describe "rosters (both directions)" do
    test "list_for_person preloads skill, ordered by name" do
      person = fixture_person()
      z = fixture_skill(%{"name" => "Zed"})
      a = fixture_skill(%{"name" => "Alpha"})
      {:ok, _} = Skills.assign_skill(person.uuid, z.uuid, [])
      {:ok, _} = Skills.assign_skill(person.uuid, a.uuid, [])

      names = Skills.list_for_person(person.uuid) |> Enum.map(& &1.skill.name)
      assert names == ["Alpha", "Zed"]
    end

    test "list_people_for_skill excludes trashed people" do
      skill = fixture_skill()
      kept = fixture_person()
      gone = fixture_person()
      {:ok, _} = Skills.assign_skill(kept.uuid, skill.uuid, [])
      {:ok, _} = Skills.assign_skill(gone.uuid, skill.uuid, [])
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
      {:ok, _} = Skills.assign_skill(has.uuid, skill.uuid, [])
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
      {:ok, _} = Skills.assign_skill(person.uuid, assigned.uuid, [])

      uuids = Skills.skills_not_assigned_to(person.uuid) |> Enum.map(& &1.uuid)
      assert free.uuid in uuids
      refute assigned.uuid in uuids
    end
  end
end
