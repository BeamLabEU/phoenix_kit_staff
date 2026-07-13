defmodule PhoenixKitStaff.Schemas.PersonSkill do
  @moduledoc """
  Join between `Person` and `Skill` — a person's assignment of a skill,
  carrying zero or more of the skill's own proficiency levels.

  `proficiency_levels` is a list of level `id`s referencing the parent
  `Skill.levels`. `[]` means "no level / not set". A single-select skill
  holds 0–1 ids; a multi-select skill holds 0–N.

  **Write path invariant:** semantic validation of the ids (they must exist
  in the parent skill's `levels`, and there must be ≤1 when the skill is
  single-select) lives in `PhoenixKitStaff.Skills`, which is the **sole**
  supported write path for assignments. This changeset only does structural
  normalisation (reject blanks, dedup) — do **not** insert a `PersonSkill`
  directly bypassing the context, or invalid/over-count ids can be persisted.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.Schemas.{Person, Skill}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          skill_uuid: UUIDv7.t() | nil,
          skill: Skill.t() | Ecto.Association.NotLoaded.t() | nil,
          staff_person_uuid: UUIDv7.t() | nil,
          staff_person: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          proficiency_levels: [String.t()],
          inserted_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_person_skills" do
    belongs_to(:skill, Skill, foreign_key: :skill_uuid, references: :uuid)

    belongs_to(:staff_person, Person,
      foreign_key: :staff_person_uuid,
      references: :uuid
    )

    field(:proficiency_levels, {:array, :string}, default: [])

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w(skill_uuid staff_person_uuid)a
  @optional ~w(proficiency_levels)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(ps, attrs) do
    ps
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> normalize_levels()
    |> assoc_constraint(:skill)
    |> assoc_constraint(:staff_person)
    |> unique_constraint([:staff_person_uuid, :skill_uuid],
      name: :phoenix_kit_staff_person_skills_person_skill_index,
      message: gettext("already has this skill")
    )
  end

  # Drop blanks and dedup while preserving order. Semantic checks (subset of
  # the skill's levels, single-vs-multiple) are the context's job.
  defp normalize_levels(changeset) do
    case fetch_change(changeset, :proficiency_levels) do
      {:ok, ids} when is_list(ids) ->
        cleaned =
          ids
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        put_change(changeset, :proficiency_levels, cleaned)

      _ ->
        changeset
    end
  end
end
