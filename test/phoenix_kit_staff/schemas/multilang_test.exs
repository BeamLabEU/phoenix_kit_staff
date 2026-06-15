defmodule PhoenixKitStaff.Schemas.MultilangTest do
  @moduledoc """
  Schema-level tests for the multilang JSONB column shipped in V122.
  Pins the contract on `localized_<field>/2` (primary-fallback semantics)
  and `validate_translations_shape` (rejects malformed JSONB).
  """

  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Schemas.{Department, Person, Skill, Team}

  describe "Department.localized_<field>/2" do
    test "returns the language override when present" do
      d = %Department{
        name: "Engineering",
        description: "Builds the product.",
        translations: %{
          "es-ES" => %{"name" => "Ingeniería", "description" => "Construye el producto."}
        }
      }

      assert Department.localized_name(d, "es-ES") == "Ingeniería"
      assert Department.localized_description(d, "es-ES") == "Construye el producto."
    end

    test "falls back to the primary column when the language is missing" do
      d = %Department{name: "Engineering", description: "Builds.", translations: %{}}

      assert Department.localized_name(d, "es-ES") == "Engineering"
      assert Department.localized_description(d, "es-ES") == "Builds."
    end

    test "falls back when the language entry exists but the field is missing" do
      d = %Department{
        name: "Engineering",
        translations: %{"es-ES" => %{"description" => "Solo descripción."}}
      }

      assert Department.localized_name(d, "es-ES") == "Engineering"
    end

    test "falls back when the language entry's field is empty string" do
      d = %Department{name: "Engineering", translations: %{"es-ES" => %{"name" => ""}}}

      assert Department.localized_name(d, "es-ES") == "Engineering"
    end

    test "falls back on nil lang argument" do
      d = %Department{name: "Engineering", translations: %{"es-ES" => %{"name" => "X"}}}

      assert Department.localized_name(d, nil) == "Engineering"
    end
  end

  describe "Team.localized_<field>/2" do
    test "primary-fallback semantics mirror Department" do
      t = %Team{
        name: "Platform",
        description: "Infra.",
        translations: %{"de-DE" => %{"name" => "Plattform"}}
      }

      assert Team.localized_name(t, "de-DE") == "Plattform"
      assert Team.localized_description(t, "de-DE") == "Infra."
      assert Team.localized_name(t, "fr-FR") == "Platform"
    end
  end

  describe "Person.localized_<field>/2" do
    test "translatable fields fall back independently" do
      p = %Person{
        job_title: "Engineer",
        bio: "Builds things.",
        notes: "—",
        translations: %{"es-ES" => %{"job_title" => "Ingeniera", "bio" => "Construye cosas."}}
      }

      assert Person.localized_job_title(p, "es-ES") == "Ingeniera"
      assert Person.localized_bio(p, "es-ES") == "Construye cosas."
      assert Person.localized_notes(p, "es-ES") == "—"
    end
  end

  describe "translatable_fields/0" do
    test "Department exposes name + description" do
      assert Department.translatable_fields() == ~w(name description)
    end

    test "Team exposes name + description" do
      assert Team.translatable_fields() == ~w(name description)
    end

    test "Person exposes job_title, bio, notes (NOT name, skills, or work_location)" do
      fields = Person.translatable_fields()
      assert "job_title" in fields
      assert "bio" in fields
      assert "notes" in fields
      refute "name" in fields
      refute "skills" in fields
      refute "work_location" in fields
    end

    test "Skill exposes name + description" do
      assert Skill.translatable_fields() == ~w(name description)
    end
  end

  describe "validate_translations_shape" do
    test "accepts a well-formed translations map on Department" do
      cs =
        Department.changeset(%Department{}, %{
          "name" => "X",
          "translations" => %{"es-ES" => %{"name" => "Y"}}
        })

      assert cs.valid?
    end

    test "rejects a translations value that isn't the expected shape on Department" do
      cs =
        Department.changeset(%Department{}, %{
          "name" => "X",
          "translations" => %{"es-ES" => "not-a-map"}
        })

      refute cs.valid?
      assert {"is not a valid translations map", _} = cs.errors[:translations]
    end

    test "rejects bad shape on Team" do
      cs =
        Team.changeset(%Team{}, %{
          "name" => "X",
          "department_uuid" => Ecto.UUID.generate(),
          "translations" => %{"es-ES" => [1, 2, 3]}
        })

      refute cs.valid?
      assert {"is not a valid translations map", _} = cs.errors[:translations]
    end

    test "rejects bad shape on Person (lang value not a map)" do
      cs =
        Person.changeset(%Person{}, %{
          "user_uuid" => Ecto.UUID.generate(),
          "status" => "active",
          "translations" => %{"es-ES" => "not-a-map"}
        })

      refute cs.valid?
      assert {"is not a valid translations map", _} = cs.errors[:translations]
    end
  end

  describe "Person.name (single full-name column)" do
    test "casts and persists on the changeset" do
      cs =
        Person.changeset(%Person{}, %{
          "user_uuid" => Ecto.UUID.generate(),
          "status" => "active",
          "name" => "Alice Chen"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :name) == "Alice Chen"
    end

    test "rejects names over the 255-char length cap" do
      long = String.duplicate("a", 256)

      cs =
        Person.changeset(%Person{}, %{
          "user_uuid" => Ecto.UUID.generate(),
          "status" => "active",
          "name" => long
        })

      refute cs.valid?
      assert {"should be at most %{count} character(s)", _} = cs.errors[:name]
    end

    test "name is optional (nil is fine)" do
      cs =
        Person.changeset(%Person{}, %{
          "user_uuid" => Ecto.UUID.generate(),
          "status" => "active"
        })

      assert cs.valid?
    end
  end
end
