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

  describe "valid_translations_shape?/1" do
    test "nil is valid (no translations stored)" do
      assert L10n.valid_translations_shape?(nil) == true
    end

    test "empty map is valid" do
      assert L10n.valid_translations_shape?(%{}) == true
    end

    test "well-formed single-language entry is valid" do
      assert L10n.valid_translations_shape?(%{"es-ES" => %{"name" => "Hola"}}) == true
    end

    test "well-formed multi-language multi-field entry is valid" do
      shape = %{
        "es-ES" => %{"name" => "X", "description" => "Y"},
        "de-DE" => %{"name" => "Z"}
      }

      assert L10n.valid_translations_shape?(shape) == true
    end

    test "nil field value is valid (signals 'fall back to primary')" do
      assert L10n.valid_translations_shape?(%{"es-ES" => %{"name" => nil}}) == true
    end

    test "non-binary lang key is rejected" do
      assert L10n.valid_translations_shape?(%{:es => %{"name" => "X"}}) == false
    end

    test "non-map field bag is rejected" do
      assert L10n.valid_translations_shape?(%{"es-ES" => "not-a-map"}) == false
      assert L10n.valid_translations_shape?(%{"es-ES" => [1, 2, 3]}) == false
    end

    test "non-binary field key is rejected" do
      assert L10n.valid_translations_shape?(%{"es-ES" => %{:name => "X"}}) == false
    end

    test "non-binary non-nil field value is rejected" do
      assert L10n.valid_translations_shape?(%{"es-ES" => %{"name" => 42}}) == false
      assert L10n.valid_translations_shape?(%{"es-ES" => %{"name" => %{}}}) == false
    end

    test "non-map root is rejected (lists, strings, atoms)" do
      assert L10n.valid_translations_shape?("string") == false
      assert L10n.valid_translations_shape?(42) == false
      assert L10n.valid_translations_shape?([1, 2, 3]) == false
      assert L10n.valid_translations_shape?(:not_a_map) == false
    end
  end
end
