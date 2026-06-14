defmodule PhoenixKitStaff.Schemas.PersonSkill do
  @moduledoc """
  Join between `Person` and `Skill` — a person's assignment of a skill,
  carrying an optional proficiency level.

  `proficiency_level` is **nullable**: `nil` means "not set" (e.g. rows
  migrated from the old free-text skills column, or an admin who hasn't
  rated it). When present it must be one of `proficiency_levels/0`.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.Schemas.{Person, Skill}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @proficiency_levels ~w(beginner intermediate advanced expert)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          skill_uuid: UUIDv7.t() | nil,
          skill: Skill.t() | Ecto.Association.NotLoaded.t() | nil,
          staff_person_uuid: UUIDv7.t() | nil,
          staff_person: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          proficiency_level: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_person_skills" do
    belongs_to(:skill, Skill, foreign_key: :skill_uuid, references: :uuid)

    belongs_to(:staff_person, Person,
      foreign_key: :staff_person_uuid,
      references: :uuid
    )

    field(:proficiency_level, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w(skill_uuid staff_person_uuid)a
  @optional ~w(proficiency_level)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(ps, attrs) do
    ps
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    # An empty `<select>` posts "" — normalize to nil ("not set") before
    # `validate_inclusion`, which skips nil but would reject "".
    |> normalize_level()
    |> validate_inclusion(:proficiency_level, @proficiency_levels,
      message: gettext("is not a valid level")
    )
    |> assoc_constraint(:skill)
    |> assoc_constraint(:staff_person)
    |> unique_constraint([:staff_person_uuid, :skill_uuid],
      name: :phoenix_kit_staff_person_skills_person_skill_index,
      message: gettext("already has this skill")
    )
  end

  defp normalize_level(changeset) do
    case get_change(changeset, :proficiency_level) do
      "" -> put_change(changeset, :proficiency_level, nil)
      _ -> changeset
    end
  end

  @doc "Allowed proficiency levels (nil/'not set' is always permitted)."
  @spec proficiency_levels() :: [String.t()]
  def proficiency_levels, do: @proficiency_levels

  @doc "Translated label for a proficiency level (`nil` → \"Not set\")."
  def proficiency_label(nil), do: gettext("Not set")
  def proficiency_label("beginner"), do: gettext("Beginner")
  def proficiency_label("intermediate"), do: gettext("Intermediate")
  def proficiency_label("advanced"), do: gettext("Advanced")
  def proficiency_label("expert"), do: gettext("Expert")
  def proficiency_label(other), do: other
end
