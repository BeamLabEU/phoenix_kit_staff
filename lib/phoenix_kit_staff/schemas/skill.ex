defmodule PhoenixKitStaff.Schemas.Skill do
  @moduledoc """
  A skill that can be assigned to staff people.

  A flat, translatable taxonomy entry (no parent — unlike `Team`, which
  belongs to a `Department`). Names are globally unique, case-insensitively
  (a `lower(name)` expression index in the DB). See `Department` for the
  `translations` shape and read-path semantics — `Skill` uses the same pattern.

  People are assigned skills many-to-many via `PhoenixKitStaff.Schemas.PersonSkill`,
  which carries the per-assignment selected level option ids.

  ## Level selectors

  A skill defines zero or more **selectors** (a.k.a. level groups) in its
  `levels` JSONB column. Each selector has a translatable `name`, its own
  `allow_multiple` toggle, and an ordered list of translatable `options`:

      [
        %{
          "id" => "<id>", "name" => "Licence category", "translations" => %{"et" => "..."},
          "allow_multiple" => true,
          "options" => [
            %{"id" => "<id>", "name" => "Category B", "translations" => %{"et" => "B-kategooria"}},
            ...
          ]
        },
        ...
      ]

  `PersonSkill.proficiency_levels` holds a **flat** array of selected option
  ids across all selectors (option ids are globally unique within a skill), so
  multiple selectors need no join-table change. Per-selector cardinality
  (≤1 unless `allow_multiple`) is enforced in `PhoenixKitStaff.Skills`.

  **Backward compatibility:** older skills stored a flat option list directly in
  `levels` (no selector wrapper) plus an `allow_multiple_levels` boolean column.
  `level_groups/1` wraps that legacy shape into a single default selector on
  read (using the legacy boolean for its `allow_multiple`), so existing rows and
  their assignments keep working; the next save persists the selector shape.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.L10n
  alias PhoenixKitStaff.Schemas.PersonSkill

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @translatable_fields ~w(name description)

  # Length cap for a selector name and a level-option name (matches skill name).
  @name_max 255

  # Stable id used for a legacy flat-levels list wrapped into one selector.
  @legacy_group_id "default"

  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @typedoc """
  A single selectable level option. `id` is a stable short identifier that
  `PersonSkill.proficiency_levels` references; `translations` maps a locale to a
  translated name (flat `lang => name`, primary fallback to `name`).
  """
  @type option :: %{required(String.t()) => String.t() | %{optional(String.t()) => String.t()}}

  @typedoc """
  A named selector (level group): a translatable `name`, an `allow_multiple`
  flag, and an ordered list of `options`.
  """
  @type level_group :: %{required(String.t()) => term()}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          translations: translations_map(),
          levels: [level_group()],
          allow_multiple_levels: boolean(),
          person_skills: [PersonSkill.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_skills" do
    field(:name, :string)
    field(:description, :string)
    field(:translations, :map, default: %{})

    # Per-skill level selectors — an ordered list of selector maps, each
    # `%{"id", "name", "translations", "allow_multiple", "options" => [...]}`.
    # See `normalize_levels/1` for the enforced shape and `level_groups/1` for
    # the legacy-flat-list read fallback.
    #
    # Backed by a **JSONB** column (V135), not a Postgres array. Postgrex
    # JSON-encodes the whole list param for a jsonb column regardless of the
    # inner Ecto type, so `{:array, :map}` round-trips correctly (covered by
    # the JSONB round-trip integration test) — do not "fix" this to a native
    # array type.
    field(:levels, {:array, :map}, default: [])

    # Legacy: a skill-wide "allow multiple levels" flag. Superseded by the
    # per-selector `allow_multiple` inside each `levels` entry; retained only as
    # the `allow_multiple` value when wrapping a legacy flat list (`level_groups/1`).
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

  # ── Normalization (write path) ─────────────────────────────────────
  #
  # `{:array, :map}` only checks "list of maps", so the selector tree is
  # validated/normalized strictly here:
  #   * a fully-empty selector (blank name AND no options) is dropped
  #   * an empty-name option row is dropped; a blank-name selector with
  #     options is kept (renders with a generic label)
  #   * missing/blank ids are generated; names are trimmed + length-capped;
  #     `translations` must be a flat `lang => name` string map
  #   * a structurally invalid selector/option, a duplicate selector id, or a
  #     duplicate option id (option ids must be globally unique within a skill)
  #     is a hard error
  defp normalize_levels(changeset) do
    case fetch_change(changeset, :levels) do
      {:ok, groups} when is_list(groups) ->
        apply_normalized_groups(changeset, groups)

      {:ok, _not_a_list} ->
        add_error(changeset, :levels, gettext("must be a list of selectors"))

      :error ->
        changeset
    end
  end

  defp apply_normalized_groups(changeset, groups) do
    normalized = Enum.map(groups, &normalize_group/1)

    if Enum.any?(normalized, &(&1 == :invalid)) do
      add_error(changeset, :levels, gettext("has an invalid selector"))
    else
      kept = Enum.reject(normalized, &(&1 == :blank))
      group_ids = Enum.map(kept, &Map.fetch!(&1, "id"))
      option_ids = Enum.flat_map(kept, fn g -> Enum.map(g["options"], &Map.fetch!(&1, "id")) end)

      cond do
        not unique?(group_ids) ->
          add_error(changeset, :levels, gettext("has duplicate selector ids"))

        not unique?(option_ids) ->
          add_error(changeset, :levels, gettext("has duplicate level ids"))

        true ->
          put_change(changeset, :levels, kept)
      end
    end
  end

  defp unique?(list), do: length(Enum.uniq(list)) == length(list)

  # A selector entry. Tolerates only well-typed input: a non-binary name/id is
  # a hard `:invalid`, never a `to_string/1` crash.
  defp normalize_group(group) when is_map(group) do
    case mget(group, "name") do
      name when is_binary(name) or is_nil(name) ->
        build_group(group, String.trim(name || ""))

      _ ->
        :invalid
    end
  end

  defp normalize_group(_), do: :invalid

  defp build_group(group, name) do
    id = mget(group, "id")
    translations = group |> mget("translations") |> normalize_translations()
    options = group |> mget("options") |> normalize_options()

    cond do
      String.length(name) > @name_max -> :invalid
      not valid_id_input?(id) -> :invalid
      translations == :invalid -> :invalid
      options == :invalid -> :invalid
      name == "" and options == [] -> :blank
      true -> assembled_group(id, name, translations, options, mget(group, "allow_multiple"))
    end
  end

  defp assembled_group(id, name, translations, options, allow_multiple) do
    %{
      "id" => normalize_id(id),
      "name" => name,
      "translations" => translations,
      "allow_multiple" => normalize_bool(allow_multiple),
      "options" => options
    }
  end

  defp normalize_options(nil), do: []

  defp normalize_options(list) when is_list(list) do
    normalized = Enum.map(list, &normalize_option/1)

    if Enum.any?(normalized, &(&1 == :invalid)),
      do: :invalid,
      else: Enum.reject(normalized, &(&1 == :blank))
  end

  defp normalize_options(_), do: :invalid

  defp normalize_option(option) when is_map(option) do
    case mget(option, "name") do
      name when is_binary(name) -> normalize_named_option(option, String.trim(name))
      nil -> :blank
      _ -> :invalid
    end
  end

  defp normalize_option(_), do: :invalid

  defp normalize_named_option(_option, ""), do: :blank

  defp normalize_named_option(option, name) do
    id = mget(option, "id")
    translations = option |> mget("translations") |> normalize_translations()

    cond do
      String.length(name) > @name_max -> :invalid
      not valid_id_input?(id) -> :invalid
      translations == :invalid -> :invalid
      true -> %{"id" => normalize_id(id), "name" => name, "translations" => translations}
    end
  end

  defp normalize_bool(true), do: true
  defp normalize_bool("true"), do: true
  defp normalize_bool(_), do: false

  # An id is either absent (generate one) or a bounded id-shaped string —
  # reject huge/garbage ids that would otherwise be interpolated into form
  # field names / DOM ids.
  defp valid_id_input?(nil), do: true

  defp valid_id_input?(id) when is_binary(id) do
    trimmed = String.trim(id)
    trimmed == "" or trimmed =~ ~r/^[A-Za-z0-9_-]{1,64}$/
  end

  defp valid_id_input?(_), do: false

  defp normalize_id(id) when is_binary(id) do
    case String.trim(id) do
      "" -> gen_level_id()
      trimmed -> trimmed
    end
  end

  defp normalize_id(_), do: gen_level_id()

  defp normalize_translations(nil), do: %{}

  defp normalize_translations(map) when is_map(map) do
    if Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      map
      |> Enum.reject(fn {_lang, name} -> String.trim(name) == "" end)
      |> Map.new()
    else
      :invalid
    end
  end

  defp normalize_translations(_), do: :invalid

  # Fetch a map key tolerant of string/atom keys (the form builds string keys;
  # callers occasionally pass atoms).
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

  # ── Level selectors (read path) ────────────────────────────────────

  @doc """
  The skill's selectors (level groups), always a list.

  Wraps a legacy flat option list (`levels` entries without an `"options"` key)
  into a single default selector, using the legacy `allow_multiple_levels`
  column for its `allow_multiple`, so old rows keep working until re-saved.
  """
  @spec level_groups(t()) :: [level_group()]
  def level_groups(%__MODULE__{levels: levels, allow_multiple_levels: legacy_multiple})
      when is_list(levels) do
    wrap_legacy(levels, legacy_multiple)
  end

  def level_groups(_), do: []

  defp wrap_legacy([], _legacy_multiple), do: []

  defp wrap_legacy(list, legacy_multiple) do
    if Enum.any?(list, &group_shaped?/1) do
      Enum.filter(list, &group_shaped?/1)
    else
      [
        %{
          "id" => @legacy_group_id,
          "name" => "",
          "translations" => %{},
          "allow_multiple" => !!legacy_multiple,
          "options" => list
        }
      ]
    end
  end

  defp group_shaped?(m) when is_map(m),
    do: Map.has_key?(m, "options") or Map.has_key?(m, :options)

  defp group_shaped?(_), do: false

  @doc "A selector's options (always a list)."
  @spec group_options(level_group()) :: [option()]
  def group_options(group) when is_map(group), do: Map.get(group, "options", []) || []
  def group_options(_), do: []

  @doc "Every option id across all selectors, in order."
  @spec all_option_ids(t()) :: [String.t()]
  def all_option_ids(%__MODULE__{} = skill) do
    skill
    |> level_groups()
    |> Enum.flat_map(fn g -> Enum.map(group_options(g), &Map.get(&1, "id")) end)
  end

  @doc "Locates `{group, option}` for an option id, or `nil`."
  @spec find_option(t(), String.t()) :: {level_group(), option()} | nil
  def find_option(%__MODULE__{} = skill, option_id) do
    skill
    |> level_groups()
    |> Enum.find_value(fn g ->
      case Enum.find(group_options(g), &(Map.get(&1, "id") == option_id)) do
        nil -> nil
        opt -> {g, opt}
      end
    end)
  end

  @doc """
  Translated selector name in `lang` (primary `name` fallback). Returns the
  fallback (possibly `""`/`nil`) — never raises.
  """
  @spec localized_group_name(t(), level_group(), String.t() | nil) :: String.t() | nil
  def localized_group_name(%__MODULE__{} = _skill, group, lang) when is_map(group),
    do: localized_map_name(group, lang)

  @doc """
  Translated option name for an option `id` in `lang` (primary `name` fallback).
  Returns `nil` for an unknown id so callers can drop stray ids — never raises.
  """
  @spec localized_option_name(t(), String.t(), String.t() | nil) :: String.t() | nil
  def localized_option_name(%__MODULE__{} = skill, id, lang) do
    case find_option(skill, id) do
      nil -> nil
      {_group, opt} -> localized_map_name(opt, lang)
    end
  end

  defp localized_map_name(map, lang) do
    translated = map |> Map.get("translations", %{}) |> Map.get(to_string(lang))

    case translated do
      t when is_binary(t) and t != "" -> t
      _ -> Map.get(map, "name")
    end
  end

  @doc "A selector's options as `[{localized_name, id}]` for chips/`<select>` in `lang`."
  @spec option_choices(t(), level_group(), String.t() | nil) :: [{String.t(), String.t()}]
  def option_choices(%__MODULE__{} = skill, group, lang) when is_map(group) do
    Enum.map(group_options(group), fn opt ->
      id = Map.get(opt, "id")
      {localized_option_name(skill, id, lang) || Map.get(opt, "name"), id}
    end)
  end

  @doc """
  Groups a flat list of selected option ids by selector, in skill order, for
  read-only display. Returns `[{group, [selected_option, ...]}]`, dropping
  selectors with no selected option and ids that match no option.
  """
  @spec selected_by_group(t(), [String.t()]) :: [{level_group(), [option()]}]
  def selected_by_group(%__MODULE__{} = skill, option_ids) when is_list(option_ids) do
    skill
    |> level_groups()
    |> Enum.map(fn g ->
      {g, Enum.filter(group_options(g), &(Map.get(&1, "id") in option_ids))}
    end)
    |> Enum.reject(fn {_g, opts} -> opts == [] end)
  end

  @doc """
  Toggles option `id` within its own selector, preserving selections in other
  selectors. A multi-select selector toggles the option in/out; a single-select
  selector replaces its selection (re-clicking the chosen option clears it).
  Unknown ids are ignored. Order is normalised by `Skills.validate_level_ids/2`
  on the way to the DB, so this need not preserve skill order.
  """
  @spec toggle_option(t(), [String.t()], String.t()) :: [String.t()]
  def toggle_option(%__MODULE__{} = skill, ids, option_id) when is_list(ids) do
    case find_option(skill, option_id) do
      {group, _opt} ->
        group_ids = Enum.map(group_options(group), &Map.get(&1, "id"))
        others = Enum.reject(ids, &(&1 in group_ids))
        within = Enum.filter(ids, &(&1 in group_ids))

        kept =
          if Map.get(group, "allow_multiple") do
            if option_id in within,
              do: List.delete(within, option_id),
              else: within ++ [option_id]
          else
            if within == [option_id], do: [], else: [option_id]
          end

        others ++ kept

      nil ->
        ids
    end
  end

  @doc "Generates a stable short (8-hex) id for a selector or option."
  @spec gen_level_id() :: String.t()
  def gen_level_id, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
