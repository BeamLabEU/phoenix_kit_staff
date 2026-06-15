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
    test "strips a removed option id from existing assignments" do
      person = fixture_person()
      {skill, ids} = fixture_skill_with_levels(["B", "C"], %{"allow_multiple" => true})
      {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, [ids["B"], ids["C"]])

      # Drop option "C" from the selector (preserving the selector + option ids).
      {:ok, _} = Skills.update(skill, %{"levels" => [keep_options(skill, [ids["B"]])]})

      assert [ps] = Skills.list_for_person(person.uuid)
      assert ps.proficiency_levels == [ids["B"]]
    end

    test "prunes assignments to one option when a selector is toggled multiple→single" do
      person = fixture_person()
      {skill, ids} = fixture_skill_with_levels(["B", "C"], %{"allow_multiple" => true})
      {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, [ids["B"], ids["C"]])

      [selector] = skill.levels
      {:ok, _} = Skills.update(skill, %{"levels" => [Map.put(selector, "allow_multiple", false)]})

      assert [ps] = Skills.list_for_person(person.uuid)
      # kept the first in selector order
      assert ps.proficiency_levels == [ids["B"]]
    end

    test "broadcasts a person-skill update to the person topic when an assignment changes" do
      alias PhoenixKitStaff.PubSub, as: StaffPubSub

      person = fixture_person()
      {skill, ids} = fixture_skill_with_levels(["B", "C"], %{"allow_multiple" => true})
      {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, [ids["B"], ids["C"]])

      # An open person page subscribes to the person topic; reconciliation must
      # reach it so the displayed levels don't stay stale.
      StaffPubSub.subscribe(StaffPubSub.topic_person(person.uuid))

      {:ok, _} = Skills.update(skill, %{"levels" => [keep_options(skill, [ids["B"]])]})

      assert_receive {:staff, :person_skill_updated, %{staff_person_uuid: psu}}
      assert psu == person.uuid
    end
  end

  describe "per-selector cardinality (multiple selectors)" do
    test "single-select selector rejects 2 of its options; a sibling multi-select accepts several" do
      person = fixture_person()

      {skill, ids} =
        fixture_skill_with_selectors([
          {"Size", false, ["S", "M"]},
          {"Colour", true, ["Red", "Green", "Blue"]}
        ])

      # Two options from the single-select "Size" selector is over-count.
      assert {:error, :too_many_levels} =
               Skills.assign_skill(person.uuid, skill.uuid, [ids["S"], ids["M"]])

      # One Size + several Colours is fine, normalised to selector→option order.
      assert {:ok, ps} =
               Skills.assign_skill(person.uuid, skill.uuid, [
                 ids["Blue"],
                 ids["S"],
                 ids["Red"]
               ])

      assert ps.proficiency_levels == [ids["S"], ids["Red"], ids["Blue"]]
    end
  end

  # Rebuild a single-selector skill's `levels` attr, keeping only the given
  # option ids (preserves the selector id, name, allow_multiple, and option ids).
  defp keep_options(skill, option_ids) do
    [selector] = skill.levels
    Map.update!(selector, "options", fn opts -> Enum.filter(opts, &(&1["id"] in option_ids)) end)
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
