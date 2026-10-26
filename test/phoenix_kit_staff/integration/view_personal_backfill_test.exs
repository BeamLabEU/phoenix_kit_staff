defmodule PhoenixKitStaff.Integration.ViewPersonalBackfillTest do
  @moduledoc """
  `staff.view_personal` narrowed what the base key shows, so
  `migrate_legacy/0` grants it once to every role that already held
  `staff` — and never again, so later roles get the narrow meaning.
  """

  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}

  @flag "staff_view_personal_backfilled"
  @sub "staff.view_personal"

  setup do
    {:ok, _} = Settings.update_setting("staff_enabled", "true")
    :ok
  end

  defp role_with_base! do
    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{"name" => "StaffRole-#{n}", "description" => "test"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "staff", nil)
    role
  end

  defp holds?(role, key), do: key in Permissions.get_permissions_for_role(role.uuid)

  test "grants the sub-key once to roles holding the base key, then sets the flag" do
    holder = role_with_base!()
    {:ok, bystander} = Roles.create_role(%{"name" => "NoStaff-#{System.unique_integer()}"})

    assert {:ok, %{view_personal_backfill: :backfilled}} = PhoenixKitStaff.migrate_legacy()
    assert holds?(holder, @sub)
    refute holds?(bystander, @sub)
    assert Settings.get_setting(@flag) == "true"

    late = role_with_base!()

    assert {:ok, %{view_personal_backfill: :already_backfilled}} =
             PhoenixKitStaff.migrate_legacy()

    refute holds?(late, @sub)
  end

  test "a revoke after the backfill sticks across boots" do
    holder = role_with_base!()
    PhoenixKitStaff.migrate_legacy()
    :ok = Permissions.revoke_permission(holder.uuid, @sub)

    PhoenixKitStaff.migrate_legacy()
    refute holds?(holder, @sub)
  end

  test "a failed grant leaves the flag unset so the next boot retries" do
    holder = role_with_base!()

    # Without the module registered the sub-key is not a known permission,
    # so the grant's changeset rejects it.
    ModuleRegistry.unregister(PhoenixKitStaff)
    on_exit(fn -> ModuleRegistry.register(PhoenixKitStaff) end)

    assert {:error, _} = PhoenixKitStaff.migrate_legacy()
    refute holds?(holder, @sub)
    refute Settings.get_setting(@flag) == "true"

    ModuleRegistry.register(PhoenixKitStaff)

    assert {:ok, %{view_personal_backfill: :backfilled}} = PhoenixKitStaff.migrate_legacy()
    assert holds?(holder, @sub)
  end

  test "the sub-key is declared on the module" do
    %{sub_permissions: subs} = PhoenixKitStaff.permission_metadata()
    assert Enum.any?(subs, &(&1.key == "view_personal"))
  end
end
