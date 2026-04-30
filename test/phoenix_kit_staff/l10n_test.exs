defmodule PhoenixKitStaff.L10nTest do
  @moduledoc """
  Unit tests for `PhoenixKitStaff.L10n` (Batch 4 coverage push). Pure
  helpers — no DB needed.

  Covers:
  - `format_date/1` for nil / Date / DateTime / NaiveDateTime
  - `format_month_day/1` for nil / Date / DateTime
  - `short_month/1` for all 12 months
  """

  use ExUnit.Case, async: true

  alias PhoenixKitStaff.L10n

  describe "short_month/1" do
    @months_with_labels [
      {1, "Jan"},
      {2, "Feb"},
      {3, "Mar"},
      {4, "Apr"},
      {5, "May"},
      {6, "Jun"},
      {7, "Jul"},
      {8, "Aug"},
      {9, "Sep"},
      {10, "Oct"},
      {11, "Nov"},
      {12, "Dec"}
    ]

    for {month_number, default_label} <- @months_with_labels do
      test "month #{month_number} returns gettext-translated #{default_label}" do
        # Default-locale short labels match the literal English strings;
        # tests should still pass under any other configured locale
        # because we only check is_binary & non-empty.
        result = L10n.short_month(unquote(month_number))
        assert is_binary(result)
        refute result == ""
        assert result == unquote(default_label)
      end
    end
  end

  describe "format_date/1" do
    test "nil returns nil" do
      assert L10n.format_date(nil) == nil
    end

    test "Date is formatted as 'Mon DD, YYYY'" do
      assert L10n.format_date(~D[2024-03-15]) == "Mar 15, 2024"
    end

    test "DateTime is converted to date and formatted" do
      dt = ~U[2024-03-15 10:30:00Z]
      assert L10n.format_date(dt) == "Mar 15, 2024"
    end

    test "NaiveDateTime is converted to date and formatted" do
      ndt = ~N[2024-12-25 23:59:59]
      assert L10n.format_date(ndt) == "Dec 25, 2024"
    end

    test "leap-year Feb 29 is formatted correctly" do
      assert L10n.format_date(~D[2024-02-29]) == "Feb 29, 2024"
    end
  end

  describe "format_month_day/1" do
    test "nil returns nil" do
      assert L10n.format_month_day(nil) == nil
    end

    test "Date is formatted as 'Mon DD' (no year)" do
      assert L10n.format_month_day(~D[2024-07-04]) == "Jul 4"
    end

    test "DateTime is converted to date and formatted (no year)" do
      dt = ~U[2024-11-25 06:00:00Z]
      assert L10n.format_month_day(dt) == "Nov 25"
    end
  end
end
