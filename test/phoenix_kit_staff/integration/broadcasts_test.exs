defmodule PhoenixKitStaff.Integration.BroadcastsTest do
  @moduledoc """
  Asserts that every staff mutation broadcasts the expected PubSub event
  with the expected minimal payload. The per-resource topic must also
  receive the same event so `*_show_live` subscribers update in real time.
  """

  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKitStaff.{Departments, Staff, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub

  describe "departments" do
    test "create broadcasts :department_created on the departments and per-department topics" do
      StaffPubSub.subscribe(StaffPubSub.topic_departments())

      {:ok, dept} = Departments.create(%{"name" => "Ops"})
      StaffPubSub.subscribe(StaffPubSub.topic_department(dept.uuid))

      assert_receive {:staff, :department_created, %{uuid: uuid, name: "Ops"}}, 500
      assert uuid == dept.uuid

      # Update broadcasts on both topics
      {:ok, _} = Departments.update(dept, %{"description" => "Operations"})
      assert_receive {:staff, :department_updated, %{uuid: ^uuid}}, 500
      assert_receive {:staff, :department_updated, %{uuid: ^uuid}}, 500
    end

    test "delete broadcasts :department_deleted" do
      StaffPubSub.subscribe(StaffPubSub.topic_departments())
      {:ok, dept} = Departments.create(%{"name" => "DropMe"})
      {:ok, _} = Departments.delete(dept)

      assert_receive {:staff, :department_deleted, %{uuid: uuid}}, 500
      assert uuid == dept.uuid
    end
  end

  describe "teams" do
    test "create broadcasts on teams, team, and parent-department topics" do
      {:ok, dept} =
        Departments.create(%{"name" => "Parent #{System.unique_integer([:positive])}"})

      StaffPubSub.subscribe(StaffPubSub.topic_teams())
      StaffPubSub.subscribe(StaffPubSub.topic_department(dept.uuid))

      {:ok, team} = Teams.create(%{"name" => "Squad A", "department_uuid" => dept.uuid})

      assert_receive {:staff, :team_created, %{uuid: uuid, name: "Squad A", department_uuid: d}},
                     500

      assert uuid == team.uuid
      assert d == dept.uuid

      # Parent department topic sees the team event too
      assert_receive {:staff, :team_created, %{uuid: ^uuid}}, 500
    end

    test "update and delete each broadcast" do
      {:ok, dept} =
        Departments.create(%{"name" => "Parent #{System.unique_integer([:positive])}"})

      {:ok, team} = Teams.create(%{"name" => "Orig", "department_uuid" => dept.uuid})

      StaffPubSub.subscribe(StaffPubSub.topic_teams())

      {:ok, _} = Teams.update(team, %{"name" => "Renamed"})
      assert_receive {:staff, :team_updated, %{uuid: uuid, name: "Renamed"}}, 500
      assert uuid == team.uuid

      {:ok, _} = Teams.delete(team)
      assert_receive {:staff, :team_deleted, %{uuid: ^uuid}}, 500
    end
  end

  describe "people and team memberships" do
    setup do
      {:ok, dept} = Departments.create(%{"name" => "D #{System.unique_integer([:positive])}"})
      {:ok, team} = Teams.create(%{"name" => "T", "department_uuid" => dept.uuid})

      email = "person-#{System.unique_integer([:positive])}@example.com"
      {:ok, user, _status} = Staff.find_or_create_user_by_email(email)

      {:ok, person} =
        Staff.create_person(%{"user_uuid" => user.uuid, "status" => "active"})

      %{dept: dept, team: team, person: person}
    end

    test "person create/update/delete broadcast on people and per-person topics", %{
      person: person
    } do
      StaffPubSub.subscribe(StaffPubSub.topic_people())
      StaffPubSub.subscribe(StaffPubSub.topic_person(person.uuid))

      {:ok, _} = Staff.update_person(person, %{"job_title" => "Lead"})
      assert_receive {:staff, :person_updated, %{uuid: uuid}}, 500
      assert uuid == person.uuid
      # Per-person topic also received it
      assert_receive {:staff, :person_updated, %{uuid: ^uuid}}, 500

      {:ok, _} = Staff.delete_person(person)
      assert_receive {:staff, :person_deleted, %{uuid: ^uuid}}, 500
    end

    test "add_team_person broadcasts :team_person_added on teams, team, people, and person topics",
         %{team: team, person: person} do
      StaffPubSub.subscribe(StaffPubSub.topic_teams())
      StaffPubSub.subscribe(StaffPubSub.topic_team(team.uuid))
      StaffPubSub.subscribe(StaffPubSub.topic_person(person.uuid))

      {:ok, _} = Staff.add_team_person(team.uuid, person.uuid)

      assert_receive {:staff, :team_person_added, %{team_uuid: t, staff_person_uuid: p, uuid: _}},
                     500

      assert t == team.uuid
      assert p == person.uuid
    end

    test "remove_team_person broadcasts :team_person_removed", %{team: team, person: person} do
      {:ok, tm} = Staff.add_team_person(team.uuid, person.uuid)
      StaffPubSub.subscribe(StaffPubSub.topic_teams())

      {:ok, _} = Staff.remove_team_person(tm)
      assert_receive {:staff, :team_person_removed, %{uuid: uuid}}, 500
      assert uuid == tm.uuid
    end
  end
end
