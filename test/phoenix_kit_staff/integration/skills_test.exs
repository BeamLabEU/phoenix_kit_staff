defmodule PhoenixKitStaff.Integration.SkillsTest do
  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.Schemas.Skill
  alias PhoenixKitStaff.Skills

  describe "CRUD" do
    test "create / get / update / delete" do
      assert {:ok, %Skill{} = skill} = Skills.create(%{"name" => "Elixir"})
      assert Skills.get(skill.uuid).name == "Elixir"
      assert Skills.get!(skill.uuid).uuid == skill.uuid

      assert {:ok, updated} = Skills.update(skill, %{"name" => "Elixir/OTP"})
      assert updated.name == "Elixir/OTP"

      assert {:ok, _} = Skills.delete(updated)
      assert Skills.get(skill.uuid) == nil
    end

    test "get/1 returns nil for a missing uuid" do
      assert Skills.get(Ecto.UUID.generate()) == nil
    end

    test "list/0 is ordered by name; count/0 counts" do
      fixture_skill(%{"name" => "Zed"})
      fixture_skill(%{"name" => "Alpha"})

      names = Skills.list() |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
      assert Skills.count() == length(names)
    end
  end

  describe "case-insensitive uniqueness (lower(name) index)" do
    test "rejects a name that differs only by case" do
      assert {:ok, _} = Skills.create(%{"name" => "Elixir"})
      assert {:error, cs} = Skills.create(%{"name" => "elixir"})
      assert :name in Keyword.keys(cs.errors)
    end
  end

  describe "delete cascade" do
    test "deleting a skill removes its assignments" do
      skill = fixture_skill()
      person = fixture_person()
      assert {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, "expert")
      assert Skills.list_for_person(person.uuid) != []

      assert {:ok, _} = Skills.delete(skill)
      assert Skills.list_for_person(person.uuid) == []
    end
  end

  describe "person_counts/0" do
    test "counts assigned people per skill" do
      skill = fixture_skill()
      p1 = fixture_person()
      p2 = fixture_person()
      {:ok, _} = Skills.assign_skill(p1.uuid, skill.uuid, nil)
      {:ok, _} = Skills.assign_skill(p2.uuid, skill.uuid, "beginner")

      assert Skills.person_counts()[skill.uuid] == 2
    end
  end
end
