defmodule PhoenixKitStaff.EdgeCasesTest do
  @moduledoc """
  Edge-case tests for free-text fields across staff schemas (Batch 3
  fix-everything pass per `feedback_test_coverage_blind_spots.md`):

  - Unicode round-trip (CJK / emoji / RTL)
  - 256-char rejection on `validate_length(:name, max: 255)`
  - SQL metacharacter literal handling (no injection, no escape leak)
  - Empty / nil inputs

  Mirrors the canonical post-Apr edge-case suite shape from
  `phoenix_kit_ai/test/phoenix_kit_ai/edge_cases_test.exs` and
  `phoenix_kit_locations/test/locations_edge_cases_test.exs`.
  """

  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.{Departments, Staff, Teams}
  alias PhoenixKitStaff.Schemas.Person

  describe "Department changeset edge cases" do
    test "Unicode CJK round-trip preserves the exact string" do
      cjk = "工程部"
      {:ok, dept} = Departments.create(%{"name" => cjk})

      reloaded = Departments.get!(dept.uuid)
      assert reloaded.name == cjk
    end

    test "Unicode emoji round-trip preserves the exact string" do
      with_emoji = "Eng 🚀 Team"
      {:ok, dept} = Departments.create(%{"name" => with_emoji})

      reloaded = Departments.get!(dept.uuid)
      assert reloaded.name == with_emoji
    end

    test "Unicode RTL round-trip preserves the exact string" do
      rtl = "قسم الهندسة"
      {:ok, dept} = Departments.create(%{"name" => rtl})

      reloaded = Departments.get!(dept.uuid)
      assert reloaded.name == rtl
    end

    test "256-char name rejected by validate_length" do
      long = String.duplicate("x", 256)

      assert {:error, changeset} = Departments.create(%{"name" => long})
      assert %{name: [_msg]} = errors_on(changeset)
      assert errors_on(changeset).name |> Enum.any?(&(&1 =~ "255"))
    end

    test "255-char name accepted (boundary)" do
      ok_len = String.duplicate("x", 255)

      assert {:ok, dept} = Departments.create(%{"name" => ok_len})
      assert byte_size(dept.name) == 255
    end

    test "empty name fails validate_required" do
      assert {:error, changeset} = Departments.create(%{"name" => ""})
      assert %{name: [_msg]} = errors_on(changeset)
    end

    test "nil name fails validate_required" do
      assert {:error, changeset} = Departments.create(%{})
      assert %{name: [_msg]} = errors_on(changeset)
    end

    test "SQL metacharacters in name are stored literally (no injection)" do
      sql_meta = "DROP TABLE; -- '\"\\;%_"
      {:ok, dept} = Departments.create(%{"name" => sql_meta})

      reloaded = Departments.get!(dept.uuid)
      assert reloaded.name == sql_meta

      # Departments table still exists.
      assert is_list(Departments.list())
    end
  end

  describe "Team changeset edge cases" do
    test "Unicode in team name round-trips" do
      dept = fixture_department()
      cjk = "チームA"

      {:ok, team} = Teams.create(%{"name" => cjk, "department_uuid" => dept.uuid})
      assert Teams.get!(team.uuid).name == cjk
    end

    test "256-char name rejected" do
      dept = fixture_department()
      long = String.duplicate("y", 256)

      assert {:error, changeset} = Teams.create(%{"name" => long, "department_uuid" => dept.uuid})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "missing department_uuid fails validate_required" do
      assert {:error, changeset} = Teams.create(%{"name" => "x"})
      assert %{department_uuid: [_]} = errors_on(changeset)
    end

    test "non-existent department_uuid fails assoc_constraint" do
      bogus = Ecto.UUID.generate()

      assert {:error, changeset} = Teams.create(%{"name" => "x", "department_uuid" => bogus})
      assert %{department: [_]} = errors_on(changeset)
    end

    test "duplicate team name in same dept rejected by unique_constraint" do
      dept = fixture_department()
      name = "Team-#{System.unique_integer([:positive])}"

      {:ok, _team1} = Teams.create(%{"name" => name, "department_uuid" => dept.uuid})

      assert {:error, changeset} = Teams.create(%{"name" => name, "department_uuid" => dept.uuid})
      assert errors_on(changeset).name |> Enum.any?(&(&1 =~ "already taken"))
    end
  end

  describe "Person changeset edge cases" do
    test "Unicode in job_title and bio round-trip" do
      cjk_title = "ソフトウェアエンジニア"
      bio_with_emoji = "Loves Elixir 🎉 and prod ops"

      person =
        fixture_person(%{
          "job_title" => cjk_title,
          "bio" => bio_with_emoji
        })

      assert person.job_title == cjk_title
      assert person.bio == bio_with_emoji
    end

    test "256-char job_title rejected by validate_length(max: 255)" do
      person = fixture_person()
      long = String.duplicate("x", 256)

      assert {:error, changeset} = Staff.update_person(person, %{"job_title" => long})
      assert errors_on(changeset).job_title |> Enum.any?(&(&1 =~ "255"))
    end

    test "invalid status rejected by validate_inclusion" do
      person = fixture_person()

      assert {:error, changeset} = Staff.update_person(person, %{"status" => "pending_review"})
      assert errors_on(changeset).status |> Enum.any?(&(&1 =~ "is invalid"))
    end

    test "invalid employment_type rejected by validate_inclusion" do
      person = fixture_person()

      assert {:error, changeset} =
               Staff.update_person(person, %{"employment_type" => "freelancer"})

      assert errors_on(changeset).employment_type |> Enum.any?(&(&1 =~ "must be one of"))
    end

    test "invalid personal_email format rejected" do
      person = fixture_person()

      assert {:error, changeset} =
               Staff.update_person(person, %{"personal_email" => "not-an-email"})

      assert errors_on(changeset).personal_email |> Enum.any?(&(&1 =~ "must be a valid email"))
    end

    test "duplicate user_uuid linkage rejected by unique_constraint" do
      person = fixture_person()

      # Try to create another person with the SAME user_uuid.
      changeset =
        Person.changeset(%Person{}, %{
          "user_uuid" => person.user_uuid,
          "status" => "active"
        })

      {:error, result_cs} = Repo.insert(changeset)
      assert errors_on(result_cs).user_uuid |> Enum.any?(&(&1 =~ "already linked"))
    end
  end

  describe "Staff.valid_email? edge cases" do
    test "common valid forms accepted" do
      assert Staff.valid_email?("a@b.co")
      assert Staff.valid_email?("foo+tag@bar.example.com")
      assert Staff.valid_email?("UPPER@CASE.COM")
    end

    test "common invalid forms rejected" do
      refute Staff.valid_email?("")
      refute Staff.valid_email?(nil)
      refute Staff.valid_email?("no-at-sign")
      refute Staff.valid_email?("@no-local")
      refute Staff.valid_email?("missing-tld@host")
      refute Staff.valid_email?(%{not: :a_string})
    end
  end

  describe "Person.skill_list/1 edge cases" do
    test "nil returns empty list" do
      assert Person.skill_list(nil) == []
    end

    test "empty string returns empty list" do
      assert Person.skill_list("") == []
    end

    test "single skill" do
      assert Person.skill_list("Elixir") == ["Elixir"]
    end

    test "comma-separated trims whitespace and skips blanks" do
      assert Person.skill_list("Elixir,  Phoenix , , LiveView") == [
               "Elixir",
               "Phoenix",
               "LiveView"
             ]
    end

    test "Unicode skills preserved" do
      assert Person.skill_list("プログラミング, 設計") == ["プログラミング", "設計"]
    end
  end

  describe "Person.{status,employment_type}_label fall-through" do
    test "status_label returns translated string for known values" do
      # The actual translated string varies by gettext config, but the
      # function MUST return a non-nil binary for known atoms (no
      # variable-arg leak through gettext).
      assert is_binary(Person.status_label("active"))
      assert is_binary(Person.status_label("inactive"))
    end

    test "status_label returns the original value for unknown statuses" do
      # Defense-in-depth fallback: a row that landed via raw SQL with
      # an out-of-band status doesn't crash the LV table render.
      assert Person.status_label("archived") == "archived"
      assert Person.status_label("") == ""
    end

    test "employment_type_label returns nil for nil and original for unknown" do
      assert Person.employment_type_label(nil) == nil
      assert Person.employment_type_label("freelancer") == "freelancer"
    end
  end
end
