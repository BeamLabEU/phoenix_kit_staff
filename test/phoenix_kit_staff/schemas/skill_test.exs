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

  describe "levels (selectors) normalization" do
    test "keeps well-formed selectors + options, generates missing ids" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{
              "id" => "sel1",
              "name" => "Licence",
              "options" => [
                %{"id" => "abc", "name" => "B", "translations" => %{"et" => "B"}},
                %{"name" => "C", "translations" => %{}}
              ]
            }
          ]
        })

      assert cs.valid?
      assert [selector] = Ecto.Changeset.get_field(cs, :levels)
      assert selector["id"] == "sel1"
      assert selector["name"] == "Licence"

      assert [%{"id" => "abc", "name" => "B"}, %{"id" => gen, "name" => "C"}] =
               selector["options"]

      assert is_binary(gen) and gen != ""
    end

    test "generates a missing selector id" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [%{"name" => "Licence", "options" => [%{"name" => "B"}]}]
        })

      assert cs.valid?
      assert [%{"id" => gen}] = Ecto.Changeset.get_field(cs, :levels)
      assert is_binary(gen) and gen != ""
    end

    test "drops blank-name options" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{
              "name" => "Licence",
              "options" => [%{"id" => "a", "name" => "B"}, %{"id" => "b", "name" => "   "}]
            }
          ]
        })

      assert cs.valid?
      assert [%{"options" => [%{"name" => "B"}]}] = Ecto.Changeset.get_field(cs, :levels)
    end

    test "drops a fully-empty selector (blank name + no options)" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{"name" => "Licence", "options" => [%{"id" => "a", "name" => "B"}]},
            %{"name" => "", "options" => []}
          ]
        })

      assert cs.valid?
      assert [%{"name" => "Licence"}] = Ecto.Changeset.get_field(cs, :levels)
    end

    test "keeps a blank-name selector that has options" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [%{"name" => "", "options" => [%{"id" => "a", "name" => "B"}]}]
        })

      assert cs.valid?

      assert [%{"name" => "", "options" => [%{"name" => "B"}]}] =
               Ecto.Changeset.get_field(cs, :levels)
    end

    test "rejects duplicate option ids across selectors" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{"name" => "S1", "options" => [%{"id" => "x", "name" => "B"}]},
            %{"name" => "S2", "options" => [%{"id" => "x", "name" => "C"}]}
          ]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "rejects duplicate selector ids" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{"id" => "s", "name" => "S1", "options" => [%{"name" => "B"}]},
            %{"id" => "s", "name" => "S2", "options" => [%{"name" => "C"}]}
          ]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "rejects a malformed option translations shape" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{
              "name" => "S",
              "options" => [%{"id" => "x", "name" => "B", "translations" => %{"et" => 123}}]
            }
          ]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "rejects a non-binary option name without crashing" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{"name" => "S", "options" => [%{"id" => "a", "name" => %{"evil" => "map"}}]}
          ]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "rejects a non-binary selector name without crashing" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [%{"name" => %{"evil" => "map"}, "options" => [%{"name" => "B"}]}]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "rejects an over-long / malformed option id" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{"name" => "S", "options" => [%{"id" => String.duplicate("z", 100), "name" => "B"}]}
          ]
        })

      refute cs.valid?
      assert :levels in errors(cs)
    end

    test "normalizes per-selector allow_multiple" do
      cs =
        Skill.changeset(%Skill{}, %{
          "name" => "Driving",
          "levels" => [
            %{"name" => "S", "allow_multiple" => "true", "options" => [%{"name" => "B"}]}
          ]
        })

      assert cs.valid?
      assert [%{"allow_multiple" => true}] = Ecto.Changeset.get_field(cs, :levels)
    end

    test "casts allow_multiple_levels (legacy column)" do
      cs = Skill.changeset(%Skill{}, %{"name" => "Driving", "allow_multiple_levels" => "true"})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :allow_multiple_levels) == true
    end
  end

  describe "selector helpers" do
    setup do
      skill = %Skill{
        name: "Driving",
        levels: [
          %{
            "id" => "lic",
            "name" => "Licence",
            "translations" => %{"et" => "Luba"},
            "allow_multiple" => true,
            "options" => [
              %{"id" => "b", "name" => "B", "translations" => %{"et" => "B-kat"}},
              %{"id" => "c", "name" => "C", "translations" => %{}}
            ]
          }
        ]
      }

      {:ok, skill: skill}
    end

    test "level_groups/1 returns the selectors", %{skill: skill} do
      assert [%{"id" => "lic", "name" => "Licence"}] = Skill.level_groups(skill)
    end

    test "level_groups/1 wraps a legacy flat list into one default selector" do
      legacy = %Skill{
        name: "Old",
        levels: [%{"id" => "b", "name" => "B"}, %{"id" => "c", "name" => "C"}],
        allow_multiple_levels: true
      }

      assert [group] = Skill.level_groups(legacy)
      assert group["name"] == ""
      assert group["allow_multiple"] == true
      assert Enum.map(group["options"], & &1["id"]) == ["b", "c"]
    end

    test "group_options/1 + all_option_ids/1", %{skill: skill} do
      [group] = Skill.level_groups(skill)
      assert Enum.map(Skill.group_options(group), & &1["id"]) == ["b", "c"]
      assert Skill.all_option_ids(skill) == ["b", "c"]
    end

    test "find_option/2 returns {group, option} or nil", %{skill: skill} do
      assert {%{"id" => "lic"}, %{"name" => "B"}} = Skill.find_option(skill, "b")
      assert Skill.find_option(skill, "zzz") == nil
    end

    test "localized_option_name/3 uses the override, falls back to primary", %{skill: skill} do
      assert Skill.localized_option_name(skill, "b", "et") == "B-kat"
      assert Skill.localized_option_name(skill, "b", "ru") == "B"
      assert Skill.localized_option_name(skill, "c", "et") == "C"
    end

    test "localized_option_name/3 returns nil for an unknown id (never crashes)", %{skill: skill} do
      assert Skill.localized_option_name(skill, "ghost", "et") == nil
    end

    test "localized_group_name/3 uses the override, falls back to primary", %{skill: skill} do
      [group] = Skill.level_groups(skill)
      assert Skill.localized_group_name(skill, group, "et") == "Luba"
      assert Skill.localized_group_name(skill, group, "ru") == "Licence"
    end

    test "option_choices/3 as {name, id} for a selector", %{skill: skill} do
      [group] = Skill.level_groups(skill)
      assert Skill.option_choices(skill, group, "et") == [{"B-kat", "b"}, {"C", "c"}]
    end

    test "selected_by_group/2 groups selected ids by selector, in skill order", %{skill: skill} do
      assert [{%{"id" => "lic"}, opts}] = Skill.selected_by_group(skill, ["c", "b"])
      assert Enum.map(opts, & &1["id"]) == ["b", "c"]
    end

    test "toggle_option/3 multi-select toggles in/out", %{skill: skill} do
      assert Skill.toggle_option(skill, [], "b") == ["b"]
      assert Skill.toggle_option(skill, ["b"], "c") == ["b", "c"]
      assert Skill.toggle_option(skill, ["b", "c"], "b") == ["c"]
    end

    test "toggle_option/3 single-select replaces within the selector" do
      skill = %Skill{
        name: "X",
        levels: [
          %{
            "id" => "g",
            "name" => "G",
            "allow_multiple" => false,
            "options" => [%{"id" => "b", "name" => "B"}, %{"id" => "c", "name" => "C"}]
          }
        ]
      }

      assert Skill.toggle_option(skill, [], "b") == ["b"]
      assert Skill.toggle_option(skill, ["b"], "c") == ["c"]
      assert Skill.toggle_option(skill, ["b"], "b") == []
    end

    test "toggle_option/3 preserves selections in other selectors" do
      skill = %Skill{
        name: "X",
        levels: [
          %{
            "id" => "g1",
            "name" => "G1",
            "allow_multiple" => false,
            "options" => [%{"id" => "a", "name" => "A"}]
          },
          %{
            "id" => "g2",
            "name" => "G2",
            "allow_multiple" => true,
            "options" => [%{"id" => "x", "name" => "X"}, %{"id" => "y", "name" => "Y"}]
          }
        ]
      }

      assert Enum.sort(Skill.toggle_option(skill, ["a", "x"], "y")) == ["a", "x", "y"]
    end
  end
end
