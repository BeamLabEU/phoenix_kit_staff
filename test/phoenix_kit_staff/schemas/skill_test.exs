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
end
