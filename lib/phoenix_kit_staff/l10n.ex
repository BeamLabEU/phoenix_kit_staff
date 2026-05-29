defmodule PhoenixKitStaff.L10n do
  @moduledoc """
  Tiny locale-aware date/time formatting helpers used by the staff UI.

  Unlike `Calendar.strftime(d, "%b %d, %Y")`, the output of these helpers
  is safe to translate: the three-letter month labels and the surrounding
  string template all go through Gettext, so a German locale produces
  `15. Jan 2025` (or whatever the translator wrote) instead of a hardcoded
  English ordering.

  The function bodies intentionally list every month as a separate
  `gettext/1` call so the string-extraction task picks up all 12 labels
  into the .pot file. Don't collapse them into a map-based lookup.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc "Formats a `Date`/`DateTime` as `Mon DD, YYYY`. Returns `nil` for nil."
  @spec format_date(Date.t() | DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def format_date(nil), do: nil

  def format_date(%DateTime{} = dt),
    do: dt |> DateTime.to_date() |> format_date()

  def format_date(%NaiveDateTime{} = dt),
    do: dt |> NaiveDateTime.to_date() |> format_date()

  def format_date(%Date{} = d),
    do: gettext("%{month} %{day}, %{year}", month: short_month(d.month), day: d.day, year: d.year)

  @doc "Formats as `Mon DD` (no year). Useful for near-term dates."
  @spec format_month_day(Date.t() | DateTime.t() | nil) :: String.t() | nil
  def format_month_day(nil), do: nil

  def format_month_day(%DateTime{} = dt),
    do: dt |> DateTime.to_date() |> format_month_day()

  def format_month_day(%Date{} = d),
    do: gettext("%{month} %{day}", month: short_month(d.month), day: d.day)

  @doc """
  True when `translations` matches the documented JSONB shape:

      %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  i.e. an outer map keyed by language code (`"es-ES"`) whose values
  are maps keyed by translatable field name (`"name"`) with string
  values. `%{}` and `nil` are valid (empty / unset). Used by every
  staff schema with a `translations` column so a programmatic caller
  can't persist garbage that the read helpers would silently fall
  back through.

  Same contract as `PhoenixKitProjects.L10n.valid_translations_shape?/1`.
  """
  @spec valid_translations_shape?(any()) :: boolean()
  def valid_translations_shape?(nil), do: true

  def valid_translations_shape?(map) when is_map(map) do
    Enum.all?(map, fn
      {lang, fields} when is_binary(lang) and is_map(fields) ->
        Enum.all?(fields, fn
          {k, v} when is_binary(k) and (is_binary(v) or is_nil(v)) -> true
          _ -> false
        end)

      _ ->
        false
    end)
  end

  def valid_translations_shape?(_), do: false

  @doc """
  Changeset guard for a `translations` JSONB column. When the cast
  produced a `:translations` change that doesn't match
  `valid_translations_shape?/1`, adds an error; otherwise returns the
  changeset untouched. Shared by every staff schema so the shape
  contract lives in one place.
  """
  @spec validate_translations(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_translations(changeset) do
    case Ecto.Changeset.get_change(changeset, :translations) do
      nil ->
        changeset

      val ->
        if valid_translations_shape?(val) do
          changeset
        else
          Ecto.Changeset.add_error(
            changeset,
            :translations,
            gettext("is not a valid translations map")
          )
        end
    end
  end

  @doc """
  Reads a translatable `field` (a DB-column name string) off `record`
  in the requested `lang`, with primary-fallback semantics: a missing
  or empty (`""`) language override returns the primary-column value.
  `lang` may be `nil` (multilang disabled), in which case the primary
  column is returned directly. Shared by every staff schema's
  `localized_<field>/2` helpers.
  """
  @spec localized_field(struct(), String.t(), String.t() | nil) :: String.t() | nil
  def localized_field(record, field, lang) do
    primary = Map.get(record, String.to_existing_atom(field))

    case lookup_translation(Map.get(record, :translations), lang, field) do
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

  @doc "Short 3-letter month name, translated (`Jan`, `Feb`, ...)."
  @spec short_month(1..12) :: String.t()
  def short_month(1), do: gettext("Jan")
  def short_month(2), do: gettext("Feb")
  def short_month(3), do: gettext("Mar")
  def short_month(4), do: gettext("Apr")
  def short_month(5), do: gettext("May")
  def short_month(6), do: gettext("Jun")
  def short_month(7), do: gettext("Jul")
  def short_month(8), do: gettext("Aug")
  def short_month(9), do: gettext("Sep")
  def short_month(10), do: gettext("Oct")
  def short_month(11), do: gettext("Nov")
  def short_month(12), do: gettext("Dec")
end
