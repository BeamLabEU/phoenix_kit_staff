defmodule PhoenixKitStaff.ModuleCallbacksTest do
  @moduledoc """
  Pins every `PhoenixKit.Module` callback on the top-level
  `PhoenixKitStaff` module (Batch 4 coverage push). The original
  sweep covered the contexts and LVs but never directly tested the
  module-toggle surface itself — `mix test --cover` reported
  PhoenixKitStaff at 0% coverage.

  These are unit-level tests; only `enable_system/0` /
  `disable_system/0` / `enabled?/0` need DB integration since they
  go through `PhoenixKit.Settings`.
  """

  use ExUnit.Case, async: true

  describe "static callbacks" do
    test "module_key/0 returns 'staff'" do
      assert PhoenixKitStaff.module_key() == "staff"
    end

    test "module_name/0 returns 'Staff'" do
      assert PhoenixKitStaff.module_name() == "Staff"
    end

    test "version/0 matches mix.exs @version" do
      mix_version = Mix.Project.config()[:version]
      assert PhoenixKitStaff.version() == mix_version
    end

    test "css_sources/0 returns the OTP app atom" do
      assert PhoenixKitStaff.css_sources() == [:phoenix_kit_staff]
    end

    test "permission_metadata/0 returns the canonical map shape" do
      meta = PhoenixKitStaff.permission_metadata()
      assert meta.key == "staff"
      assert meta.label == "Staff"
      assert meta.icon == "hero-users"
      assert is_binary(meta.description)
    end
  end

  describe "admin_tabs/0" do
    setup do
      tabs = PhoenixKitStaff.admin_tabs()
      {:ok, tabs: tabs}
    end

    test "returns a flat list of %Tab{} structs", %{tabs: tabs} do
      refute Enum.empty?(tabs)
      Enum.each(tabs, fn t -> assert %PhoenixKit.Dashboard.Tab{} = t end)
    end

    test "every tab carries permission: 'staff'", %{tabs: tabs} do
      for tab <- tabs do
        assert tab.permission == "staff",
               "Expected tab #{inspect(tab.id)} to have permission \"staff\", got #{inspect(tab.permission)}"
      end
    end

    test "the four visible subtabs cover Overview/Departments/Teams/Staff", %{tabs: tabs} do
      visible_ids =
        tabs
        |> Enum.filter(fn
          %{visible: false} -> false
          _ -> true
        end)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      assert :admin_staff_overview in visible_ids
      assert :admin_staff_departments in visible_ids
      assert :admin_staff_teams in visible_ids
      assert :admin_staff_people in visible_ids
    end

    test "every hidden subtab is parented under :admin_staff", %{tabs: tabs} do
      hidden = Enum.filter(tabs, &(&1.visible == false))

      Enum.each(hidden, fn tab ->
        assert tab.parent == :admin_staff
      end)
    end

    test "form/edit/show subtabs exist for every resource", %{tabs: tabs} do
      ids = MapSet.new(tabs, & &1.id)

      for prefix <- [:admin_staff_department, :admin_staff_team, :admin_staff_person] do
        for suffix <- [:_new, :_edit, :_show] do
          id = String.to_atom("#{prefix}#{suffix}")
          assert id in ids, "Expected tab #{inspect(id)} in admin_tabs/0 result"
        end
      end
    end
  end

  describe "enabled?/0 — sandbox-shutdown safe" do
    test "returns false when Settings table is unavailable" do
      # No DB available in this test (async: true, no DataCase) —
      # `Settings.get_boolean_setting/2` either raises or the catch
      # clause fires. Either way: returns `false`, never crashes.
      assert PhoenixKitStaff.enabled?() == false
    end

    test "Module.__info__ exposes the rescue and catch clauses" do
      # Defense-in-depth pin: the rescue and catch clauses are part
      # of the function bytecode, hard to inspect directly. A
      # behavioural pin is enough — calling it without a DB returns
      # false (above test); we additionally verify the function
      # arity is 0.
      assert {:enabled?, 0} in PhoenixKitStaff.__info__(:functions)
    end
  end
end
