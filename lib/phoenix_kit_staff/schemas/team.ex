defmodule PhoenixKitStaff.Schemas.Team do
  @moduledoc """
  A team inside a department.

  See `PhoenixKitStaff.Schemas.Department` for the translations
  shape and read-path semantics — Team uses the same pattern.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.L10n
  alias PhoenixKitStaff.Schemas.{Department, TeamMembership}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @translatable_fields ~w(name description)

  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          translations: translations_map(),
          department_uuid: UUIDv7.t() | nil,
          department: Department.t() | Ecto.Association.NotLoaded.t() | nil,
          team_memberships: [TeamMembership.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_teams" do
    field(:name, :string)
    field(:description, :string)
    field(:translations, :map, default: %{})

    belongs_to(:department, Department, foreign_key: :department_uuid, references: :uuid)
    has_many(:team_memberships, TeamMembership, foreign_key: :team_uuid, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @required ~w(name department_uuid)a
  @optional ~w(description translations)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(team, attrs) do
    team
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_translations_shape()
    |> assoc_constraint(:department)
    |> unique_constraint(:name,
      name: :phoenix_kit_staff_teams_department_name_index,
      message: gettext("already taken in this department")
    )
  end

  defp validate_translations_shape(changeset) do
    case get_change(changeset, :translations) do
      nil ->
        changeset

      val ->
        if L10n.valid_translations_shape?(val) do
          changeset
        else
          add_error(changeset, :translations, "is not a valid translations map")
        end
    end
  end

  @doc "DB-column field names that participate in the `translations` JSONB."
  @spec translatable_fields() :: [String.t()]
  def translatable_fields, do: @translatable_fields

  @spec localized_name(t(), String.t() | nil) :: String.t() | nil
  def localized_name(%__MODULE__{} = t, lang), do: localized_field(t, "name", lang)

  @spec localized_description(t(), String.t() | nil) :: String.t() | nil
  def localized_description(%__MODULE__{} = t, lang), do: localized_field(t, "description", lang)

  defp localized_field(t, field, lang) do
    primary = Map.get(t, String.to_existing_atom(field))

    case lookup_translation(t.translations, lang, field) do
      nil -> primary
      "" -> primary
      val -> val
    end
  end

  defp lookup_translation(translations, lang, field)
       when is_map(translations) and is_binary(lang) do
    case Map.get(translations, lang) do
      %{} = lang_map -> Map.get(lang_map, field)
      _ -> nil
    end
  end

  defp lookup_translation(_translations, _lang, _field), do: nil
end
