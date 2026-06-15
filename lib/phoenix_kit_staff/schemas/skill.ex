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

  # Length cap for a single proficiency-level name (matches the skill name cap).
  @level_name_max 255

  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @typedoc """
  A single proficiency level on a skill. `id` is a stable short identifier that
  `PersonSkill.proficiency_levels` references; `translations` maps a locale to a
  translated name (flat `lang => name`, primary fallback to `name`).
  """
  @type level :: %{
          required(String.t()) => String.t() | %{optional(String.t()) => String.t()}
        }

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          translations: translations_map(),
          levels: [level()],
          allow_multiple_levels: boolean(),
          person_skills: [PersonSkill.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_skills" do
    field(:name, :string)
    field(:description, :string)
    field(:translations, :map, default: %{})

    # Per-skill proficiency levels — an ordered list of maps, each
    # `%{"id" => ..., "name" => ..., "translations" => %{lang => name}}`. See
    # `normalize_levels/1` for the enforced shape.
    #
    # Backed by a **JSONB** column (V135), not a Postgres array. Postgrex
    # JSON-encodes the whole list param for a jsonb column regardless of the
    # inner Ecto type, so `{:array, :map}` round-trips correctly (covered by
    # the JSONB round-trip integration test) — do not "fix" this to a native
    # array type.
    field(:levels, {:array, :map}, default: [])

    # Whether an assignment may carry more than one level (e.g. driving-licence
    # categories held at once) or exactly one (a single beginner→expert rung).
    field(:allow_multiple_levels, :boolean, default: false)

    has_many(:person_skills, PersonSkill, foreign_key: :skill_uuid, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @required ~w(name)a
  @optional ~w(description translations levels allow_multiple_levels)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> L10n.validate_translations()
    |> normalize_levels()
    # Case-insensitive global uniqueness is enforced by the
    # `lower(name)` expression index — map it by name so a collision
    # ("Elixir" vs "elixir") surfaces as a friendly changeset error.
    |> unique_constraint(:name,
      name: :phoenix_kit_staff_skills_lower_name_index,
      message: gettext("already taken")
    )
  end

  # Strict shape enforcement for the `levels` JSONB — `{:array, :map}` only
  # checks "list of maps", so we validate/normalize each entry here:
  #   * blank-name levels are dropped (an empty editor row)
  #   * a missing/blank `id` gets one generated (defensive — the form assigns
  #     ids on add, this is the safety net)
  #   * `name` is trimmed and length-capped; `translations` must be a flat
  #     `lang => name` string map (blank values dropped)
  #   * a structurally invalid level, or a real duplicate id, is a hard error
  defp normalize_levels(changeset) do
    case fetch_change(changeset, :levels) do
      {:ok, levels} when is_list(levels) ->
        apply_normalized_levels(changeset, levels)

      {:ok, _not_a_list} ->
        add_error(changeset, :levels, gettext("must be a list of levels"))

      :error ->
        changeset
    end
  end

  defp apply_normalized_levels(changeset, levels) do
    normalized = Enum.map(levels, &normalize_level/1)

    if Enum.any?(normalized, &(&1 == :invalid)) do
      add_error(changeset, :levels, gettext("has an invalid level"))
    else
      kept = Enum.reject(normalized, &(&1 == :blank))
      ids = Enum.map(kept, &Map.fetch!(&1, "id"))

      if length(Enum.uniq(ids)) == length(ids) do
        put_change(changeset, :levels, kept)
      else
        add_error(changeset, :levels, gettext("has duplicate level ids"))
      end
    end
  end

  # Tolerate only well-typed input: a non-binary `name`/`id` (e.g. a crafted
  # nested param posting a map) is a hard `:invalid`, never a `to_string/1`
  # crash; an absent/blank name is a droppable empty row.
  defp normalize_level(level) when is_map(level) do
    case mget(level, "name") do
      name when is_binary(name) -> normalize_named_level(level, String.trim(name))
      nil -> :blank
      _ -> :invalid
    end
  end

  defp normalize_level(_), do: :invalid

  defp normalize_named_level(_level, ""), do: :blank

  defp normalize_named_level(level, name) do
    id = mget(level, "id")
    translations = level |> mget("translations") |> normalize_level_translations()

    cond do
      String.length(name) > @level_name_max -> :invalid
      not valid_id_input?(id) -> :invalid
      translations == :invalid -> :invalid
      true -> %{"id" => normalize_level_id(id), "name" => name, "translations" => translations}
    end
  end

  # An id is either absent (generate one) or a bounded id-shaped string —
  # reject huge/garbage ids that would otherwise be interpolated into form
  # field names / DOM ids.
  defp valid_id_input?(nil), do: true

  defp valid_id_input?(id) when is_binary(id) do
    trimmed = String.trim(id)
    trimmed == "" or trimmed =~ ~r/^[A-Za-z0-9_-]{1,64}$/
  end

  defp valid_id_input?(_), do: false

  defp normalize_level_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> gen_level_id()
      trimmed -> trimmed
    end
  end

  defp normalize_level_id(_), do: gen_level_id()

  defp normalize_level_translations(nil), do: %{}

  defp normalize_level_translations(map) when is_map(map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      map
      |> Enum.reject(fn {_lang, name} -> String.trim(name) == "" end)
      |> Map.new()
    else
      :invalid
    end
  end

  defp normalize_level_translations(_), do: :invalid

  # Fetch a map key tolerant of string/atom keys (the form builds string keys;
  # callers occasionally pass atoms). Only ever called on a level map.
  defp mget(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end

  @doc "DB-column field names that participate in the `translations` JSONB."
  @spec translatable_fields() :: [String.t()]
  def translatable_fields, do: @translatable_fields

  @spec localized_name(t(), String.t() | nil) :: String.t() | nil
  def localized_name(%__MODULE__{} = s, lang), do: L10n.localized_field(s, "name", lang)

  @spec localized_description(t(), String.t() | nil) :: String.t() | nil
  def localized_description(%__MODULE__{} = s, lang),
    do: L10n.localized_field(s, "description", lang)

  # ── Proficiency levels ─────────────────────────────────────────────

  @doc "The skill's level maps (always a list)."
  @spec levels(t()) :: [level()]
  def levels(%__MODULE__{levels: levels}) when is_list(levels), do: levels
  def levels(_), do: []

  @doc "The skill's level ids, in order."
  @spec level_ids(t()) :: [String.t()]
  def level_ids(%__MODULE__{} = skill), do: Enum.map(levels(skill), &Map.get(&1, "id"))

  @doc "The level map for `id`, or `nil`."
  @spec find_level(t(), String.t()) :: level() | nil
  def find_level(%__MODULE__{} = skill, id),
    do: Enum.find(levels(skill), &(Map.get(&1, "id") == id))

  @doc """
  Translated name for a level `id` in `lang` (primary `name` fallback).
  Returns `nil` for an unknown id so callers can drop stray ids without
  crashing — never raises.
  """
  @spec localized_level_name(t(), String.t(), String.t() | nil) :: String.t() | nil
  def localized_level_name(%__MODULE__{} = skill, id, lang) do
    case find_level(skill, id) do
      nil ->
        nil

      level ->
        translated = level |> Map.get("translations", %{}) |> Map.get(to_string(lang))

        case translated do
          t when is_binary(t) and t != "" -> t
          _ -> Map.get(level, "name")
        end
    end
  end

  @doc "Levels as `[{localized_name, id}]` for `<select>`/chip options in `lang`."
  @spec level_options(t(), String.t() | nil) :: [{String.t(), String.t()}]
  def level_options(%__MODULE__{} = skill, lang) do
    skill
    |> levels()
    |> Enum.map(fn level ->
      id = Map.get(level, "id")
      {localized_level_name(skill, id, lang) || Map.get(level, "name"), id}
    end)
  end

  @doc "Generates a stable short (8-hex) level id."
  @spec gen_level_id() :: String.t()
  def gen_level_id, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
