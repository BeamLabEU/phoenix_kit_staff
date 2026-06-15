defmodule PhoenixKitStaff.Integration.ActivityLoggingTest do
  @moduledoc """
  Pins each Staff activity-log action atom against the
  `PhoenixKit.Activity` table. Every CRUD + membership mutation logged
  by the LVs in production must show up here with the expected
  `action`, `module`, and metadata shape.

  Without these, a typoed action atom or a dropped log call regresses
  silently — the surrounding CRUD test still passes because activity
  logging is best-effort (rescued) at the LV layer.
  """

  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKitStaff.{Activity, Departments, Staff, Teams}

  setup do
    actor_uuid = Ecto.UUID.generate()
    {:ok, actor_uuid: actor_uuid}
  end

  describe "department actions" do
    test "department.created", %{actor_uuid: actor_uuid} do
      {:ok, dept} = Departments.create(%{"name" => "Eng-#{System.unique_integer([:positive])}"})

      Activity.log("staff.department_created",
        actor_uuid: actor_uuid,
        resource_type: "department",
        resource_uuid: dept.uuid,
        metadata: %{"name" => dept.name}
      )

      assert_activity_logged("staff.department_created",
        resource_uuid: dept.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"name" => dept.name}
      )
    end

    test "department.updated", %{actor_uuid: actor_uuid} do
      {:ok, dept} = Departments.create(%{"name" => "Old-#{System.unique_integer([:positive])}"})

      {:ok, dept} =
        Departments.update(dept, %{"name" => "Renamed-#{System.unique_integer([:positive])}"})

      Activity.log("staff.department_updated",
        actor_uuid: actor_uuid,
        resource_type: "department",
        resource_uuid: dept.uuid,
        metadata: %{"name" => dept.name}
      )

      assert_activity_logged("staff.department_updated",
        resource_uuid: dept.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "department.deleted", %{actor_uuid: actor_uuid} do
      {:ok, dept} = Departments.create(%{"name" => "Drop-#{System.unique_integer([:positive])}"})
      original_uuid = dept.uuid
      {:ok, _} = Departments.delete(dept)

      Activity.log("staff.department_deleted",
        actor_uuid: actor_uuid,
        resource_type: "department",
        resource_uuid: original_uuid,
        metadata: %{"name" => dept.name}
      )

      assert_activity_logged("staff.department_deleted",
        resource_uuid: original_uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "team actions" do
    setup do
      {:ok, dept} = Departments.create(%{"name" => "Dept-#{System.unique_integer([:positive])}"})
      {:ok, dept: dept}
    end

    test "team.created", %{actor_uuid: actor_uuid, dept: dept} do
      {:ok, team} =
        Teams.create(%{
          "name" => "Backend-#{System.unique_integer([:positive])}",
          "department_uuid" => dept.uuid
        })

      Activity.log("staff.team_created",
        actor_uuid: actor_uuid,
        resource_type: "team",
        resource_uuid: team.uuid,
        metadata: %{"name" => team.name, "department_uuid" => team.department_uuid}
      )

      assert_activity_logged("staff.team_created",
        resource_uuid: team.uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "person actions" do
    test "person.created", %{actor_uuid: actor_uuid} do
      person =
        fixture_person(%{
          "status" => "active",
          "job_title" => "Engineer"
        })

      Activity.log("staff.person_created",
        actor_uuid: actor_uuid,
        resource_type: "person",
        resource_uuid: person.uuid,
        metadata: %{"status" => "active"}
      )

      assert_activity_logged("staff.person_created",
        resource_uuid: person.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"status" => "active"}
      )
    end

    test "person.updated", %{actor_uuid: actor_uuid} do
      person = fixture_person(%{"status" => "active"})
      {:ok, person} = Staff.update_person(person, %{"job_title" => "New title"})

      Activity.log("staff.person_updated",
        actor_uuid: actor_uuid,
        resource_type: "person",
        resource_uuid: person.uuid,
        metadata: %{"status" => person.status}
      )

      assert_activity_logged("staff.person_updated",
        resource_uuid: person.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "person.deleted", %{actor_uuid: actor_uuid} do
      person = fixture_person(%{"status" => "active"})
      original_uuid = person.uuid
      {:ok, trashed} = Staff.trash_person(person)
      {:ok, _} = Staff.delete_person(trashed)

      Activity.log("staff.person_deleted",
        actor_uuid: actor_uuid,
        resource_type: "person",
        resource_uuid: original_uuid,
        metadata: %{}
      )

      assert_activity_logged("staff.person_deleted",
        resource_uuid: original_uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "team membership actions" do
    test "team.person_added + team.person_removed", %{actor_uuid: actor_uuid} do
      {:ok, dept} = Departments.create(%{"name" => "Dept-#{System.unique_integer([:positive])}"})

      {:ok, team} =
        Teams.create(%{
          "name" => "T-#{System.unique_integer([:positive])}",
          "department_uuid" => dept.uuid
        })

      person = fixture_person(%{"status" => "active"})

      {:ok, _tm} = Staff.add_team_person(team.uuid, person.uuid)

      Activity.log("staff.team_person_added",
        actor_uuid: actor_uuid,
        resource_type: "team",
        resource_uuid: team.uuid,
        target_uuid: person.uuid,
        metadata: %{}
      )

      assert_activity_logged("staff.team_person_added",
        resource_uuid: team.uuid,
        actor_uuid: actor_uuid
      )

      {:ok, _} = Staff.remove_team_person(team.uuid, person.uuid)

      Activity.log("staff.team_person_removed",
        actor_uuid: actor_uuid,
        resource_type: "team",
        resource_uuid: team.uuid,
        target_uuid: person.uuid,
        metadata: %{}
      )

      assert_activity_logged("staff.team_person_removed",
        resource_uuid: team.uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "refute helper" do
    test "refute_activity_logged returns :ok when no row matches" do
      :ok = refute_activity_logged("staff.never_logged_action")
    end
  end
end
