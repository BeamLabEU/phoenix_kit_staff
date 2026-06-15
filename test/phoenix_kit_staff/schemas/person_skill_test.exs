defmodule PhoenixKitStaff.Schemas.PersonSkillTest do
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Schemas.PersonSkill

  defp uuids,
    do: %{"staff_person_uuid" => Ecto.UUID.generate(), "skill_uuid" => Ecto.UUID.generate()}

  describe "changeset/2" do
    test "valid with both uuids and no levels" do
      cs = PersonSkill.changeset(%PersonSkill{}, uuids())
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :proficiency_levels) == []
    end

    test "keeps a list of level ids" do
      cs =
        PersonSkill.changeset(
          %PersonSkill{},
          Map.put(uuids(), "proficiency_levels", ["a1", "b2"])
        )

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :proficiency_levels) == ["a1", "b2"]
    end

    test "drops blanks and dedups while preserving order" do
      cs =
        PersonSkill.changeset(
          %PersonSkill{},
          Map.put(uuids(), "proficiency_levels", ["a1", "", "  ", "b2", "a1"])
        )

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :proficiency_levels) == ["a1", "b2"]
    end

    test "both uuids are required" do
      cs = PersonSkill.changeset(%PersonSkill{}, %{})
      refute cs.valid?
      assert :staff_person_uuid in Keyword.keys(cs.errors)
      assert :skill_uuid in Keyword.keys(cs.errors)
    end
  end
end
