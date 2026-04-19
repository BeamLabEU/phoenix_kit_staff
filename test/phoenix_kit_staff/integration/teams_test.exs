defmodule PhoenixKitStaff.Integration.TeamsTest do
  @moduledoc """
  Integration test for `Teams` CRUD and the cascading-delete behaviour
  from V100 (deleting a department drops its teams).
  """

  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.{Departments, Teams}

  defp build_dept do
    {:ok, dept} =
      Departments.create(%{"name" => "Dept #{System.unique_integer([:positive])}"})

    dept
  end

  describe "CRUD" do
    test "create → update → delete round-trip" do
      dept = build_dept()

      assert {:ok, team} =
               Teams.create(%{
                 "name" => "Engineering",
                 "department_uuid" => dept.uuid
               })

      assert team.name == "Engineering"

      assert {:ok, updated} = Teams.update(team, %{"description" => "Builds widgets"})
      assert updated.description == "Builds widgets"

      assert {:ok, _} = Teams.delete(updated)
      assert Teams.get(updated.uuid) == nil
    end

    test "list/1 filters by department" do
      d1 = build_dept()
      d2 = build_dept()
      {:ok, _} = Teams.create(%{"name" => "Alpha", "department_uuid" => d1.uuid})
      {:ok, _} = Teams.create(%{"name" => "Beta", "department_uuid" => d2.uuid})

      names = Teams.list(department_uuid: d1.uuid) |> Enum.map(& &1.name)
      assert "Alpha" in names
      refute "Beta" in names
    end
  end

  describe "validations" do
    test "requires name and department_uuid" do
      assert {:error, cs} = Teams.create(%{"name" => ""})
      errors = errors_on(cs)
      assert errors[:name] != nil
      assert errors[:department_uuid] != nil
    end

    test "name must be unique within a department (case-insensitive)" do
      dept = build_dept()
      {:ok, _} = Teams.create(%{"name" => "Platform", "department_uuid" => dept.uuid})

      assert {:error, cs} =
               Teams.create(%{"name" => "platform", "department_uuid" => dept.uuid})

      assert %{name: [_ | _]} = errors_on(cs)
    end

    test "same name is allowed in a different department" do
      d1 = build_dept()
      d2 = build_dept()
      {:ok, _} = Teams.create(%{"name" => "Platform", "department_uuid" => d1.uuid})

      assert {:ok, _} = Teams.create(%{"name" => "Platform", "department_uuid" => d2.uuid})
    end
  end

  describe "cascade" do
    test "deleting a department deletes its teams (V100 ON DELETE CASCADE)" do
      dept = build_dept()
      {:ok, team} = Teams.create(%{"name" => "Growth", "department_uuid" => dept.uuid})

      {:ok, _} = Departments.delete(dept)

      assert Teams.get(team.uuid) == nil
    end
  end
end
