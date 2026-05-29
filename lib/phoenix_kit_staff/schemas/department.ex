defmodule PhoenixKitStaff.Schemas.Department do
  @moduledoc """
  Top-level organizational unit containing teams.

  ## Translations

  `name` and `description` are translatable. The primary-language
  values stay in the dedicated columns; secondary-language overrides
  live in `translations` (JSONB) keyed by language code, e.g.

      %{"es-ES" => %{"name" => "Ingeniería", "description" => "..."}}

  Reads use `localized_name/2` and `localized_description/2` with
  primary-fallback semantics: an empty / missing override returns
  the primary column value.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.L10n
  alias PhoenixKitStaff.Schemas.Team

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @translatable_fields ~w(name description)

  @typedoc """
  JSONB map of secondary-language overrides. Same shape as the
  projects module's `translations`.
  """
  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          translations: translations_map(),
          teams: [Team.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_departments" do
    field(:name, :string)
    field(:description, :string)
    field(:translations, :map, default: %{})

    has_many(:teams, Team, foreign_key: :department_uuid, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @required ~w(name)a
  @optional ~w(description translations)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(dept, attrs) do
    dept
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_translations_shape()
    |> unique_constraint(:name,
      name: :phoenix_kit_staff_departments_name_index,
      message: gettext("already taken")
    )
  end

  # Shape guard for the JSONB so a programmatic caller can't persist
  # garbage. The form layer cleans inputs upstream; this is the
  # defence-in-depth boundary at the schema.
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

  @doc """
  Returns the department's name in the requested language. Empty /
  missing override falls back to the primary `name` column.

  `lang` may be `nil` (multilang disabled) — in that case the primary
  column is returned directly.
  """
  @spec localized_name(t(), String.t() | nil) :: String.t() | nil
  def localized_name(%__MODULE__{} = d, lang), do: localized_field(d, "name", lang)

  @doc "Same as `localized_name/2` for `description`."
  @spec localized_description(t(), String.t() | nil) :: String.t() | nil
  def localized_description(%__MODULE__{} = d, lang), do: localized_field(d, "description", lang)

  defp localized_field(d, field, lang) do
    primary = Map.get(d, String.to_existing_atom(field))

    case lookup_translation(d.translations, lang, field) do
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
