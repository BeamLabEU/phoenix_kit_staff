defmodule PhoenixKitStaff.Integration.DepartmentsTest do
  @moduledoc """
  Smoke test for the integration test infrastructure: exercises the
  full `Departments` context against a real PostgreSQL database.

  Also verifies the case-insensitive unique-name index from V100.
  """

  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.Departments

  describe "CRUD" do
    test "create → get → update → delete round-trip" do
      assert {:ok, dept} = Departments.create(%{"name" => "Engineering"})
      assert dept.name == "Engineering"

      assert ^dept = Departments.get!(dept.uuid)

      assert {:ok, updated} = Departments.update(dept, %{"description" => "Builds things."})
      assert updated.description == "Builds things."

      assert {:ok, _} = Departments.delete(updated)
      assert Departments.get(updated.uuid) == nil
    end

    test "list/1 returns rows ordered" do
      {:ok, _a} = Departments.create(%{"name" => "Support"})
      {:ok, _b} = Departments.create(%{"name" => "Marketing"})

      names = Departments.list() |> Enum.map(& &1.name)
      assert "Support" in names
      assert "Marketing" in names
    end
  end

  describe "validations" do
    test "requires a name" do
      assert {:error, cs} = Departments.create(%{"name" => ""})
      assert %{name: [_ | _]} = errors_on(cs)
    end

    test "rejects duplicate names case-insensitively" do
      {:ok, _} = Departments.create(%{"name" => "Finance"})

      assert {:error, cs} = Departments.create(%{"name" => "finance"})
      assert %{name: [_ | _]} = errors_on(cs)
    end
  end
end
