defmodule PhoenixKitStaff.Schemas.Skill do
  @moduledoc """
  A skill that can be assigned to staff people.

  A flat, translatable taxonomy entry (no parent — unlike `Team`, which
  belongs to a `Department`). Names are globally unique, case-insensitively
  (a `lower(name)` expression index in the DB). See `Department` for the
  `translations` shape and read-path semantics — `Skill` uses the same pattern.

  People are assigned skills many-to-many via `PhoenixKitStaff.Schemas.PersonSkill`,
  which carries the per-assignment proficiency level.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.L10n
  alias PhoenixKitStaff.Schemas.PersonSkill

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @translatable_fields ~w(name description)

  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          translations: translations_map(),
          person_skills: [PersonSkill.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_skills" do
    field(:name, :string)
    field(:description, :string)
    field(:translations, :map, default: %{})

    has_many(:person_skills, PersonSkill, foreign_key: :skill_uuid, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @required ~w(name)a
  @optional ~w(description translations)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> L10n.validate_translations()
    # Case-insensitive global uniqueness is enforced by the
    # `lower(name)` expression index — map it by name so a collision
    # ("Elixir" vs "elixir") surfaces as a friendly changeset error.
    |> unique_constraint(:name,
      name: :phoenix_kit_staff_skills_lower_name_index,
      message: gettext("already taken")
    )
  end

  @doc "DB-column field names that participate in the `translations` JSONB."
  @spec translatable_fields() :: [String.t()]
  def translatable_fields, do: @translatable_fields

  @spec localized_name(t(), String.t() | nil) :: String.t() | nil
  def localized_name(%__MODULE__{} = s, lang), do: L10n.localized_field(s, "name", lang)

  @spec localized_description(t(), String.t() | nil) :: String.t() | nil
  def localized_description(%__MODULE__{} = s, lang),
    do: L10n.localized_field(s, "description", lang)
end
