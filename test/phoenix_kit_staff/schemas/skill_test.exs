defmodule PhoenixKitStaff.Schemas.SkillTest do
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Schemas.Skill

  defp errors(changeset), do: Keyword.keys(changeset.errors)

  describe "changeset/2" do
    test "valid with just a name" do
      cs = Skill.changeset(%Skill{}, %{"name" => "Elixir"})
      assert cs.valid?
    end

    test "name is required" do
      cs = Skill.changeset(%Skill{}, %{"name" => ""})
      refute cs.valid?
      assert :name in errors(cs)
    end

    test "name has a max length" do
      cs = Skill.changeset(%Skill{}, %{"name" => String.duplicate("x", 256)})
      refute cs.valid?
      assert :name in errors(cs)
    end

    test "accepts description + translations" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Elixir",
          "description" => "Functional language",
          "translations" => %{"es-ES" => %{"name" => "Elixir", "description" => "Lenguaje"}}
        })

      assert cs.valid?
    end

    test "rejects a malformed translations shape" do
      cs =
        Skill.changeset(%Skill{}, %{"name" => "Elixir", "translations" => %{"es-ES" => "nope"}})

      refute cs.valid?
      assert :translations in errors(cs)
    end
  end

  describe "translatable_fields/0" do
    test "is name + description" do
      assert Skill.translatable_fields() == ~w(name description)
    end
  end

  describe "localized_name/2" do
    test "falls back to the primary value when no override" do
      skill = %Skill{name: "Elixir", translations: %{}}
      assert Skill.localized_name(skill, "es-ES") == "Elixir"
    end

    test "returns the language override when present" do
      skill = %Skill{name: "Elixir", translations: %{"es-ES" => %{"name" => "Elixir-es"}}}
      assert Skill.localized_name(skill, "es-ES") == "Elixir-es"
    end
  end

  describe "levels normalization" do
    test "keeps well-formed levels, generates a missing id" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{"id" => "abc", "name" => "B", "translations" => %{"et" => "B"}},
            %{"name" => "C", "translations" => %{}}
          ]
        })

      assert cs.valid?
      levels = Ecto.Changeset.get_field(cs, :levels)
      assert [%{"id" => "abc", "name" => "B"}, %{"id" => gen, "name" => "C"}] = levels
      assert is_binary(gen) and gen != ""
    end

    test "drops blank-name levels" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [%{"id" => "a", "name" => "B"}, %{"id" => "b", "name" => "   "}]
        })

      assert cs.valid?
      assert [%{"name" => "B"}] = Ecto.Changeset.get_field(cs, :levels)
    end

    test "rejects duplicate ids" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [%{"id" => "x", "name" => "B"}, %{"id" => "x", "name" => "C"}]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "rejects a malformed level translations shape" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [%{"id" => "x", "name" => "B", "translations" => %{"et" => 123}}]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "rejects a non-binary level name without crashing" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [%{"id" => "a", "name" => %{"evil" => "map"}}]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "rejects an over-long / malformed level id" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [%{"id" => String.duplicate("z", 100), "name" => "B"}]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "casts allow_multiple_levels" do
      cs = Skill.changeset(%Skill{}, %{"name" => "Driving", "allow_multiple_levels" => "true"})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :allow_multiple_levels) == true
    end
  end

  describe "level helpers" do
    setup do
      skill = %Skill{
        name: "Driving",
        levels: [
          %{"id" => "b", "name" => "B", "translations" => %{"et" => "B-kat"}},
          %{"id" => "c", "name" => "C", "translations" => %{}}
        ]
      }

      {:ok, skill: skill}
    end

    test "level_ids/1 in order", %{skill: skill} do
      assert Skill.level_ids(skill) == ["b", "c"]
    end

    test "find_level/2", %{skill: skill} do
      assert %{"name" => "B"} = Skill.find_level(skill, "b")
      assert Skill.find_level(skill, "zzz") == nil
    end

    test "localized_level_name/3 uses the override, falls back to primary", %{skill: skill} do
      assert Skill.localized_level_name(skill, "b", "et") == "B-kat"
      assert Skill.localized_level_name(skill, "b", "ru") == "B"
      assert Skill.localized_level_name(skill, "c", "et") == "C"
    end

    test "localized_level_name/3 returns nil for an unknown id (never crashes)", %{skill: skill} do
      assert Skill.localized_level_name(skill, "ghost", "et") == nil
    end

    test "level_options/2 as {name, id}", %{skill: skill} do
      assert Skill.level_options(skill, "et") == [{"B-kat", "b"}, {"C", "c"}]
    end
  end
end
