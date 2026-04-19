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
  def format_date(nil), do: nil

  def format_date(%DateTime{} = dt),
    do: dt |> DateTime.to_date() |> format_date()

  def format_date(%NaiveDateTime{} = dt),
    do: dt |> NaiveDateTime.to_date() |> format_date()

  def format_date(%Date{} = d),
    do: gettext("%{month} %{day}, %{year}", month: short_month(d.month), day: d.day, year: d.year)

  @doc "Formats as `Mon DD` (no year). Useful for near-term dates."
  def format_month_day(nil), do: nil

  def format_month_day(%DateTime{} = dt),
    do: dt |> DateTime.to_date() |> format_month_day()

  def format_month_day(%Date{} = d),
    do: gettext("%{month} %{day}", month: short_month(d.month), day: d.day)

  @doc "Short 3-letter month name, translated (`Jan`, `Feb`, ...)."
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
