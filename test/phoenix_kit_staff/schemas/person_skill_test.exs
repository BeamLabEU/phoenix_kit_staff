defmodule PhoenixKitStaff.Schemas.PersonSkillTest do
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Schemas.PersonSkill

  defp uuids,
    do: %{"staff_person_uuid" => Ecto.UUID.generate(), "skill_uuid" => Ecto.UUID.generate()}

  describe "changeset/2" do
    test "valid with both uuids and no level" do
      cs = PersonSkill.changeset(%PersonSkill{}, uuids())
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :proficiency_level) == nil
    end

    test "valid with a known proficiency level" do
      cs = PersonSkill.changeset(%PersonSkill{}, Map.put(uuids(), "proficiency_level", "expert"))
      assert cs.valid?
    end

    test "blank level ('') normalizes to nil (not set)" do
      cs = PersonSkill.changeset(%PersonSkill{}, Map.put(uuids(), "proficiency_level", ""))
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :proficiency_level) == nil
    end

    test "rejects an unknown level" do
      cs = PersonSkill.changeset(%PersonSkill{}, Map.put(uuids(), "proficiency_level", "wizard"))
      refute cs.valid?
      assert :proficiency_level in Keyword.keys(cs.errors)
    end

    test "both uuids are required" do
      cs = PersonSkill.changeset(%PersonSkill{}, %{})
      refute cs.valid?
      assert :staff_person_uuid in Keyword.keys(cs.errors)
      assert :skill_uuid in Keyword.keys(cs.errors)
    end
  end

  describe "proficiency_levels/0 + proficiency_label/1" do
    test "the four levels" do
      assert PersonSkill.proficiency_levels() == ~w(beginner intermediate advanced expert)
    end

    test "labels every level and nil" do
      assert PersonSkill.proficiency_label(nil) == "Not set"
      assert PersonSkill.proficiency_label("beginner") == "Beginner"
      assert PersonSkill.proficiency_label("intermediate") == "Intermediate"
      assert PersonSkill.proficiency_label("advanced") == "Advanced"
      assert PersonSkill.proficiency_label("expert") == "Expert"
    end

    test "falls through on an unknown value" do
      assert PersonSkill.proficiency_label("weird") == "weird"
    end
  end
end
