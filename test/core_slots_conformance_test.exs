defmodule PhoenixKitStaff.CoreSlotsConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The pages are built on core components, and two of the slots they fill were
  added to core after the 2.42.1 release. Against a core that lacks one, the
  slot is a compile warning and then a render crash (`ArgumentError: lists in
  Phoenix.HTML ... got invalid entry: %{__slot__: ...}`) on every page that
  fills it, which reads as dozens of unrelated LiveView failures.

  This names the cause instead. When it fails, the resolved `:phoenix_kit` is
  older than the release that carries the slot: raise the floor of the
  `:phoenix_kit` pin in `mix.exs` (keeping the compound form that
  `core_pin_conformance_test.exs` enforces) once that core release is
  published, or run against a checkout with `PHOENIX_KIT_PATH=../phoenix_kit`.
  """

  alias PhoenixKitWeb.Components.Core.{FormSection, TableDefault}

  @required [
    {TableDefault, :table_default, :toolbar_primary,
     "every list's create button sits in the table's toolbar"},
    {FormSection, :form_section, :actions,
     "the Teams / Skills / Add-staff sections' header buttons"}
  ]

  for {mod, fun, slot, why} <- @required do
    test "#{inspect(mod)}.#{fun}/1 declares the :#{slot} slot (#{why})" do
      assert Code.ensure_loaded?(unquote(mod))

      slots =
        unquote(mod).__components__()
        |> Map.fetch!(unquote(fun))
        |> Map.fetch!(:slots)
        |> Enum.map(& &1.name)

      assert unquote(slot) in slots,
             "the resolved :phoenix_kit lacks the :#{unquote(slot)} slot on " <>
               "#{inspect(unquote(mod))}.#{unquote(fun)}/1 — it needs a core release " <>
               "newer than the lockfile's; bump the pin floor once it is published"
    end
  end
end
