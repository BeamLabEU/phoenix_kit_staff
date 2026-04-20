defmodule PhoenixKitStaff.Integration.StaffQueriesTest do
  @moduledoc """
  Integration tests for the two read-path queries that do non-trivial
  shaping: `Staff.upcoming_birthdays/1` (SQL-side anniversary arithmetic,
  leap-year handling, window boundary) and `Staff.org_tree/0` (department
  → team → person hierarchy plus dept-only and fully-unassigned buckets).
  """

  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKitStaff.{Departments, Staff, Teams}

  defp unique_email, do: "person-#{System.unique_integer([:positive])}@example.com"

  defp create_person(attrs) do
    {:ok, user, _status} = Staff.find_or_create_user_by_email(unique_email())

    base = %{"user_uuid" => user.uuid, "status" => "active"}
    {:ok, person} = Staff.create_person(Map.merge(base, stringify(attrs)))
    person
  end

  defp stringify(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp days_from_today(days) do
    Date.utc_today() |> Date.add(days)
  end

  describe "upcoming_birthdays/1" do
    test "includes someone whose birthday is today (days_until == 0)" do
      today = Date.utc_today()
      # Use a birth year well in the past so the person is adult.
      dob = Date.new!(1990, today.month, today.day)
      p = create_person(%{date_of_birth: dob})

      assert [%{person: person, days_until: 0, next_birthday: next}] =
               Staff.upcoming_birthdays(30)

      assert person.uuid == p.uuid
      assert next == today
    end

    test "includes a birthday on the final day of the window" do
      target = days_from_today(30)
      dob = Date.new!(1985, target.month, target.day)
      p = create_person(%{date_of_birth: dob})

      assert [%{person: person, days_until: 30}] = Staff.upcoming_birthdays(30)
      assert person.uuid == p.uuid
    end

    test "excludes a birthday one day past the window" do
      target = days_from_today(31)
      dob = Date.new!(1985, target.month, target.day)
      _p = create_person(%{date_of_birth: dob})

      assert Staff.upcoming_birthdays(30) == []
    end

    test "wraps across year boundary when the anniversary this year has passed" do
      today = Date.utc_today()
      # Person born in a year that HAS passed this calendar year if today > Jan 1.
      # Pick a date 10 days ago as their DOB month/day — this year's anniversary
      # is past, next year's is ~355 days out — well outside a 30d window.
      past = Date.add(today, -10)
      dob = Date.new!(1980, past.month, past.day)
      _p = create_person(%{date_of_birth: dob})

      assert Staff.upcoming_birthdays(30) == []

      # But a 365-day window catches the wrap.
      assert [%{days_until: d}] = Staff.upcoming_birthdays(365)
      assert d > 300 and d <= 365
    end

    test "handles Feb 29 DOB without crashing (Postgres normalizes to Feb 28 in non-leap years)" do
      dob = Date.new!(2000, 2, 29)
      p = create_person(%{date_of_birth: dob})

      # Always reachable within a year, regardless of whether this or next
      # year is a leap year. We just assert no crash and that the person
      # appears with a sensible days_until.
      results = Staff.upcoming_birthdays(366)
      assert Enum.any?(results, fn r -> r.person.uuid == p.uuid end)

      result = Enum.find(results, &(&1.person.uuid == p.uuid))
      assert result.days_until >= 0 and result.days_until <= 366
    end

    test "excludes inactive people" do
      today = Date.utc_today()
      dob = Date.new!(1990, today.month, today.day)
      _p = create_person(%{date_of_birth: dob, status: "inactive"})

      assert Staff.upcoming_birthdays(30) == []
    end

    test "excludes people with no date_of_birth" do
      _p = create_person(%{})

      assert Staff.upcoming_birthdays(30) == []
    end

    test "sorts by days_until ascending" do
      today = Date.utc_today()
      in_5 = Date.add(today, 5)
      in_15 = Date.add(today, 15)

      p_today = create_person(%{date_of_birth: Date.new!(1990, today.month, today.day)})
      p_5 = create_person(%{date_of_birth: Date.new!(1990, in_5.month, in_5.day)})
      p_15 = create_person(%{date_of_birth: Date.new!(1990, in_15.month, in_15.day)})

      uuids = Staff.upcoming_birthdays(30) |> Enum.map(& &1.person.uuid)
      assert uuids == [p_today.uuid, p_5.uuid, p_15.uuid]
    end

    test "defaults to a 30-day window" do
      target = days_from_today(29)
      dob = Date.new!(1985, target.month, target.day)
      _p = create_person(%{date_of_birth: dob})

      assert [_] = Staff.upcoming_birthdays()
    end

    test "accepts window_days = 0 (today only)" do
      today = Date.utc_today()
      tomorrow = Date.add(today, 1)

      p_today = create_person(%{date_of_birth: Date.new!(1990, today.month, today.day)})
      _p_tom = create_person(%{date_of_birth: Date.new!(1990, tomorrow.month, tomorrow.day)})

      assert [%{person: person}] = Staff.upcoming_birthdays(0)
      assert person.uuid == p_today.uuid
    end
  end

  describe "org_tree/0" do
    test "empty DB returns empty departments and empty unassigned" do
      assert %{departments: [], unassigned_people: []} = Staff.org_tree()
    end

    test "groups people by team within departments" do
      {:ok, dept} = Departments.create(%{"name" => "Engineering"})
      {:ok, team} = Teams.create(%{"name" => "Platform", "department_uuid" => dept.uuid})

      p = create_person(%{})
      {:ok, _} = Staff.add_team_person(team.uuid, p.uuid)

      tree = Staff.org_tree()
      [dept_node] = tree.departments

      assert dept_node.department.uuid == dept.uuid
      [team_node] = dept_node.teams
      assert team_node.team.uuid == team.uuid
      assert [%{uuid: uuid}] = team_node.people
      assert uuid == p.uuid
    end

    test "places a dept-only person (has primary_department but no team) under the department" do
      {:ok, dept} = Departments.create(%{"name" => "Research"})
      p = create_person(%{primary_department_uuid: dept.uuid})

      tree = Staff.org_tree()
      [dept_node] = tree.departments

      assert dept_node.teams == []
      assert [%{uuid: uuid}] = dept_node.dept_only_people
      assert uuid == p.uuid
      assert tree.unassigned_people == []
    end

    test "places a fully unassigned person (no team, no primary_department) in unassigned" do
      p = create_person(%{})

      assert %{departments: [], unassigned_people: [%{uuid: uuid}]} = Staff.org_tree()
      assert uuid == p.uuid
    end

    test "a person on a team is NOT also listed in dept_only_people (even if primary dept matches)" do
      {:ok, dept} = Departments.create(%{"name" => "Ops"})
      {:ok, team} = Teams.create(%{"name" => "SRE", "department_uuid" => dept.uuid})

      p = create_person(%{primary_department_uuid: dept.uuid})
      {:ok, _} = Staff.add_team_person(team.uuid, p.uuid)

      [dept_node] = Staff.org_tree().departments
      assert dept_node.dept_only_people == []
      assert [team_node] = dept_node.teams
      assert [%{uuid: uuid}] = team_node.people
      assert uuid == p.uuid
    end

    test "preloads the user on every person in the tree (no N+1 on email access)" do
      {:ok, dept} = Departments.create(%{"name" => "Design"})
      {:ok, team} = Teams.create(%{"name" => "Brand", "department_uuid" => dept.uuid})

      p = create_person(%{})
      {:ok, _} = Staff.add_team_person(team.uuid, p.uuid)

      [dept_node] = Staff.org_tree().departments
      [team_node] = dept_node.teams
      [person] = team_node.people

      # If user isn't preloaded, this would be a %Ecto.Association.NotLoaded{}
      # and the match would fail.
      assert %PhoenixKit.Users.Auth.User{} = person.user
      assert is_binary(person.user.email)
    end

    test "sorts teams by name within each department" do
      {:ok, dept} = Departments.create(%{"name" => "Sales"})
      {:ok, _z} = Teams.create(%{"name" => "Zulu", "department_uuid" => dept.uuid})
      {:ok, _a} = Teams.create(%{"name" => "Alpha", "department_uuid" => dept.uuid})
      {:ok, _m} = Teams.create(%{"name" => "Mike", "department_uuid" => dept.uuid})

      [dept_node] = Staff.org_tree().departments
      assert Enum.map(dept_node.teams, & &1.team.name) == ["Alpha", "Mike", "Zulu"]
    end
  end
end
