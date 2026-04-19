defmodule PhoenixKitStaff.Schemas.PersonTest do
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Schemas.Person

  describe "employment_type_label/1" do
    test "converts known atoms to human labels" do
      assert Person.employment_type_label("full_time") == "Full-time"
      assert Person.employment_type_label("part_time") == "Part-time"
      assert Person.employment_type_label("contractor") == "Contractor"
      assert Person.employment_type_label("intern") == "Intern"
      assert Person.employment_type_label("temporary") == "Temporary"
    end

    test "nil returns nil" do
      assert Person.employment_type_label(nil) == nil
    end

    test "unknown value passes through" do
      assert Person.employment_type_label("weird") == "weird"
    end
  end

  describe "skill_list/1" do
    test "nil returns empty list" do
      assert Person.skill_list(nil) == []
    end

    test "blank string returns empty list" do
      assert Person.skill_list("") == []
      assert Person.skill_list("   ") == []
    end

    test "splits and trims comma-separated skills" do
      assert Person.skill_list("Elixir, Phoenix, PostgreSQL") == [
               "Elixir",
               "Phoenix",
               "PostgreSQL"
             ]
    end

    test "drops empty entries" do
      assert Person.skill_list("Elixir,,Phoenix, ") == ["Elixir", "Phoenix"]
    end

    test "single item with no commas" do
      assert Person.skill_list("Elixir") == ["Elixir"]
    end
  end
end
