defmodule PhoenixKitStaff.Staff.Org do
  @moduledoc """
  Read-model / reporting over the staff org: the upcoming-birthdays widget and
  the full department → team → people org tree.

  Extracted from `PhoenixKitStaff.Staff`, which keeps thin delegators
  (`Staff.org_tree/0`, `Staff.upcoming_birthdays/1`) so the public API is
  unchanged. `org_tree/0` reads the people roster via `Staff.list_people/0`
  (which already excludes trashed people).
  """

  import Ecto.Query

  alias PhoenixKitStaff.{Departments, Staff}
  alias PhoenixKitStaff.Schemas.{Person, TeamMembership}

  # Soft-delete sentinel — mirrors `Person.soft_delete_status/0`.
  @soft_delete_status "trashed"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Returns upcoming birthdays within the given window (default 30 days),
  sorted by days-until-birthday.
  """
  @spec upcoming_birthdays(non_neg_integer()) :: [
          %{person: Person.t(), next_birthday: Date.t(), days_until: non_neg_integer()}
        ]
  def upcoming_birthdays(window_days \\ 30) do
    today = Date.utc_today()
    window_days = max(window_days, 0)

    from(p in Person,
      where: p.status == "active" and not is_nil(p.date_of_birth),
      # `today` is bound as a UTC date param (not Postgres `CURRENT_DATE`,
      # which is the DB session timezone) so the SQL window matches the
      # Elixir `days_until` computation below exactly, regardless of the
      # connection's TimeZone setting.
      where:
        fragment(
          """
          ((CASE
             WHEN (? + (EXTRACT(YEAR FROM ?)::int - EXTRACT(YEAR FROM ?)::int) * INTERVAL '1 year')::date < ?
               THEN (? + (EXTRACT(YEAR FROM ?)::int - EXTRACT(YEAR FROM ?)::int + 1) * INTERVAL '1 year')::date
             ELSE (? + (EXTRACT(YEAR FROM ?)::int - EXTRACT(YEAR FROM ?)::int) * INTERVAL '1 year')::date
           END) - ?) <= ?
          """,
          p.date_of_birth,
          type(^today, :date),
          p.date_of_birth,
          type(^today, :date),
          p.date_of_birth,
          type(^today, :date),
          p.date_of_birth,
          p.date_of_birth,
          type(^today, :date),
          p.date_of_birth,
          type(^today, :date),
          ^window_days
        ),
      preload: [:user]
    )
    |> repo().all()
    |> Enum.map(fn p ->
      {next, days} = next_birthday_and_days(p.date_of_birth, today)
      %{person: p, next_birthday: next, days_until: days}
    end)
    |> Enum.sort_by(& &1.days_until)
  end

  defp next_birthday_and_days(dob, today) do
    this_year = anniversary_in_year(dob, today.year)

    next =
      if Date.compare(this_year, today) == :lt do
        anniversary_in_year(dob, today.year + 1)
      else
        this_year
      end

    {next, Date.diff(next, today)}
  end

  # Returns the anniversary of `dob` in `year`, normalising Feb 29 → Feb 28
  # only when `year` itself is non-leap. Mirrors Postgres `INTERVAL '1 year'`
  # arithmetic so the SQL filter and the Elixir display stay consistent.
  defp anniversary_in_year(dob, year) do
    case Date.new(year, dob.month, dob.day) do
      {:ok, d} -> d
      {:error, _} -> Date.new!(year, dob.month, 28)
    end
  end

  @doc """
  Returns the full org tree:
  %{
    departments: [%{department: ..., teams: [...], dept_only_people: [...]}],
    unassigned_people: [...]
  }
  """
  @spec org_tree() :: %{
          departments: [
            %{
              department: PhoenixKitStaff.Schemas.Department.t(),
              teams: [%{team: PhoenixKitStaff.Schemas.Team.t(), people: [Person.t()]}],
              dept_only_people: [Person.t()]
            }
          ],
          unassigned_people: [Person.t()]
        }
  def org_tree do
    departments = Departments.list(preload: [:teams])
    all_people = Staff.list_people()

    # `list_people/0` already excludes trashed, so dept-only and
    # unassigned buckets are clean. Team rosters come straight from
    # memberships, so drop memberships whose person is trashed here.
    all_memberships =
      from(tm in TeamMembership, preload: [staff_person: [:user]])
      |> repo().all()
      |> Enum.reject(&(&1.staff_person.status == @soft_delete_status))

    people_by_team =
      Enum.group_by(all_memberships, & &1.team_uuid, & &1.staff_person)

    person_team_ids = MapSet.new(all_memberships, & &1.staff_person_uuid)

    dept_tree =
      Enum.map(departments, fn dept ->
        teams =
          dept.teams
          |> Enum.sort_by(& &1.name)
          |> Enum.map(fn team ->
            people =
              Map.get(people_by_team, team.uuid, [])
              |> Enum.sort_by(fn p -> (p.user && p.user.email) || "" end)

            %{team: team, people: people}
          end)

        dept_only_people =
          all_people
          |> Enum.filter(fn p ->
            p.primary_department_uuid == dept.uuid and
              not MapSet.member?(person_team_ids, p.uuid)
          end)

        %{department: dept, teams: teams, dept_only_people: dept_only_people}
      end)

    unassigned =
      Enum.filter(all_people, fn p ->
        p.primary_department_uuid == nil and
          not MapSet.member?(person_team_ids, p.uuid)
      end)

    %{departments: dept_tree, unassigned_people: unassigned}
  end
end
