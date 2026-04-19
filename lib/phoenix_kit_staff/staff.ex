defmodule PhoenixKitStaff.Staff do
  @moduledoc """
  Context for staff (people) and team memberships.

  Staff are linked 1:1 to a PhoenixKit user (decision A for MVP).
  A person can belong to multiple teams via `TeamMembership`.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitStaff.Departments
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Person, TeamMembership}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @doc "Returns the regex used to validate emails throughout the staff module."
  def email_regex, do: @email_regex

  @doc "Whether the given string looks like a valid email."
  def valid_email?(email) when is_binary(email), do: String.match?(email, @email_regex)
  def valid_email?(_), do: false

  # ── Rename placeholder user email ───────────────────────────────────

  @doc """
  Renames the email of an unclaimed placeholder user directly in place.
  Safe only for users we created via `find_or_create_user_by_email/1`
  that nobody has signed up for yet. Refuses if another user already
  exists with the new email.
  """
  def rename_placeholder_email(%User{} = user, new_email) do
    new_email = String.trim(new_email)
    current = user.email

    cond do
      new_email == "" ->
        {:error, gettext("Email cannot be blank.")}

      new_email == current ->
        :ok

      not placeholder?(user) ->
        {:error,
         gettext("This user has already claimed their account — email cannot be changed here.")}

      Auth.get_user_by_email(new_email) != nil ->
        {:error, gettext("An account with that email already exists.")}

      true ->
        user
        |> Ecto.Changeset.cast(%{email: new_email}, [:email])
        |> Ecto.Changeset.validate_format(:email, @email_regex)
        |> Ecto.Changeset.unique_constraint(:email)
        |> repo().update()
    end
  end

  defp placeholder?(user) do
    is_nil(user.confirmed_at) and
      Map.get(user.custom_fields || %{}, "source") == "staff_placeholder"
  end

  # ── Find or create user by email ────────────────────────────────────

  @doc """
  Find-or-create a user by email, then create a staff person linked to
  that user. If the person creation fails AND we just created a brand-new
  placeholder user, delete the placeholder so we don't leave orphans.

  Returns `{:ok, person, user_status}` or `{:error, reason}`.
  """
  def create_person_with_user(email, person_attrs) do
    with {:ok, user, user_status} <- find_or_create_user_by_email(email),
         attrs = Map.put(person_attrs, "user_uuid", user.uuid),
         {:ok, person} <- create_person_or_rollback(attrs, user, user_status) do
      {:ok, person, user_status}
    end
  end

  defp create_person_or_rollback(attrs, user, user_status) do
    case create_person(attrs) do
      {:ok, person} ->
        {:ok, person}

      {:error, _} = err ->
        if user_status == :created, do: _ = repo().delete(user)
        err
    end
  end

  @doc """
  Finds an existing user by email, or creates a placeholder user with no
  usable password. When the person later registers or logs in via OAuth
  with the same email, PhoenixKit's built-in lookup links them automatically.
  """
  def find_or_create_user_by_email(email) when is_binary(email) do
    case String.trim(email) do
      "" -> {:error, :blank_email}
      trimmed -> find_or_register_placeholder(trimmed)
    end
  end

  defp find_or_register_placeholder(email) do
    case Auth.get_user_by_email(email) do
      %User{} = user -> {:ok, user, :existing}
      nil -> register_placeholder(email)
    end
  end

  defp register_placeholder(email) do
    random_password =
      :crypto.strong_rand_bytes(24) |> Base.url_encode64() |> binary_part(0, 24)

    attrs = %{
      "email" => email,
      "password" => random_password <> "Aa1!",
      "custom_fields" => %{"source" => "staff_placeholder"}
    }

    with {:ok, user} <- Auth.register_user(attrs), do: {:ok, user, :created}
  end

  # ── Eligible users (for person form) ────────────────────────────────

  @doc """
  Users who don't yet have a staff profile. When `exclude_person_uuid`
  is passed (edit mode), that person's linked user is kept in the list.
  """
  def eligible_users(opts \\ []) do
    exclude_person_uuid = Keyword.get(opts, :exclude_person_uuid)

    linked_user_uuids_query =
      from(p in Person,
        select: p.user_uuid
      )

    linked_user_uuids_query =
      if exclude_person_uuid do
        from([p] in linked_user_uuids_query, where: p.uuid != ^exclude_person_uuid)
      else
        linked_user_uuids_query
      end

    from(u in User,
      where: u.uuid not in subquery(linked_user_uuids_query),
      order_by: [asc: u.email]
    )
    |> repo().all()
  end

  # ── People ─────────────────────────────────────────────────────────

  @doc "Lists people. Accepts `:preload`, `:status` filter, and `:search` (matches user email)."
  def list_people(opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])
    status = Keyword.get(opts, :status)
    search = opts |> Keyword.get(:search) |> normalize_search()

    Person
    |> maybe_filter_status(status)
    |> maybe_filter_search(search)
    |> order_by([p], asc: p.status, desc: p.inserted_at)
    |> preload(^preload)
    |> repo().all()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query
  defp maybe_filter_status(query, status), do: where(query, [p], p.status == ^status)

  defp maybe_filter_search(query, nil), do: query

  defp maybe_filter_search(query, term) do
    like = "%#{term}%"

    from(p in query,
      join: u in assoc(p, :user),
      where: ilike(u.email, ^like)
    )
  end

  defp normalize_search(nil), do: nil
  defp normalize_search(""), do: nil
  defp normalize_search(s) when is_binary(s), do: String.trim(s)

  @doc "Fetches a person by the linked user's uuid, or `nil` if no staff profile exists."
  def get_person_by_user_uuid(user_uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> where([p], p.user_uuid == ^user_uuid)
    |> preload(^preload)
    |> repo().one()
  end

  @doc "Fetches a person by uuid. Raises if not found."
  def get_person!(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> preload(^preload)
    |> repo().get!(uuid)
  end

  @doc "Fetches a person by uuid, or `nil` if not found."
  def get_person(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> preload(^preload)
    |> repo().get(uuid)
  end

  @doc "Returns a changeset for the given person."
  def change_person(%Person{} = p, attrs \\ %{}), do: Person.changeset(p, attrs)

  @doc "Inserts a person and broadcasts `:person_created` on success."
  def create_person(attrs) do
    with {:ok, person} <- %Person{} |> Person.changeset(attrs) |> repo().insert() do
      StaffPubSub.broadcast_person(:person_created, %{uuid: person.uuid})
      {:ok, person}
    end
  end

  @doc "Updates a person and broadcasts `:person_updated` on success."
  def update_person(%Person{} = p, attrs) do
    with {:ok, updated} <- p |> Person.changeset(attrs) |> repo().update() do
      StaffPubSub.broadcast_person(:person_updated, %{uuid: updated.uuid})
      {:ok, updated}
    end
  end

  @doc "Deletes a person and broadcasts `:person_deleted` on success."
  def delete_person(%Person{} = p) do
    with {:ok, deleted} <- repo().delete(p) do
      StaffPubSub.broadcast_person(:person_deleted, %{uuid: deleted.uuid})
      {:ok, deleted}
    end
  end

  @doc "Total number of people."
  def count_people, do: repo().aggregate(Person, :count, :uuid)

  # ── Upcoming birthdays ─────────────────────────────────────────────

  @doc """
  Returns upcoming birthdays within the given window (default 30 days),
  sorted by days-until-birthday.
  """
  def upcoming_birthdays(window_days \\ 30) do
    today = Date.utc_today()

    Person
    |> where([p], p.status == "active" and not is_nil(p.date_of_birth))
    |> preload([:user])
    |> repo().all()
    |> Enum.map(fn p ->
      {next, days} = next_birthday_and_days(p.date_of_birth, today)
      %{person: p, next_birthday: next, days_until: days}
    end)
    |> Enum.filter(&(&1.days_until <= window_days))
    |> Enum.sort_by(& &1.days_until)
  end

  defp next_birthday_and_days(dob, today) do
    this_year =
      case Date.new(today.year, dob.month, dob.day) do
        {:ok, d} -> d
        {:error, _} -> Date.new!(today.year, dob.month, min(dob.day, 28))
      end

    next =
      if Date.compare(this_year, today) == :lt do
        Date.new!(today.year + 1, dob.month, min(dob.day, 28))
      else
        this_year
      end

    {next, Date.diff(next, today)}
  end

  # ── Org tree ───────────────────────────────────────────────────────

  @doc """
  Returns the full org tree:
  %{
    departments: [%{department: ..., teams: [...], dept_only_people: [...]}],
    unassigned_people: [...]
  }
  """
  def org_tree do
    departments = Departments.list(preload: [:teams])
    all_people = list_people()

    people_by_team =
      from(tm in TeamMembership,
        preload: [staff_person: [:user]]
      )
      |> repo().all()
      |> Enum.group_by(& &1.team_uuid, & &1.staff_person)

    person_team_ids =
      from(tm in TeamMembership, select: tm.staff_person_uuid)
      |> repo().all()
      |> MapSet.new()

    dept_tree =
      Enum.map(departments, fn dept ->
        teams =
          dept.teams
          |> Enum.sort_by(& &1.name)
          |> Enum.map(fn team ->
            people =
              Map.get(people_by_team, team.uuid, [])
              |> Enum.sort_by(fn p -> p.user && p.user.email end)

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

  # ── Team memberships ───────────────────────────────────────────────

  @doc "Memberships on a given team, preloaded with staff_person and user."
  def list_team_memberships(team_uuid) do
    TeamMembership
    |> where([tm], tm.team_uuid == ^team_uuid)
    |> preload(staff_person: [:user])
    |> order_by([tm], asc: tm.inserted_at)
    |> repo().all()
  end

  @doc "All memberships a given person belongs to, with team and department preloaded."
  def list_memberships_for_person(person_uuid) do
    TeamMembership
    |> where([tm], tm.staff_person_uuid == ^person_uuid)
    |> preload(team: [:department])
    |> order_by([tm], asc: tm.inserted_at)
    |> repo().all()
  end

  @doc "Adds a person to a team and broadcasts `:team_person_added`."
  def add_team_person(team_uuid, staff_person_uuid) do
    with {:ok, tm} <-
           %TeamMembership{}
           |> TeamMembership.changeset(%{
             team_uuid: team_uuid,
             staff_person_uuid: staff_person_uuid
           })
           |> repo().insert() do
      StaffPubSub.broadcast_team_membership(:team_person_added, %{
        team_uuid: tm.team_uuid,
        staff_person_uuid: tm.staff_person_uuid,
        uuid: tm.uuid
      })

      {:ok, tm}
    end
  end

  @doc "Removes a team membership (by struct or by team/person uuids) and broadcasts `:team_person_removed`."
  def remove_team_person(%TeamMembership{} = tm) do
    with {:ok, deleted} <- repo().delete(tm) do
      StaffPubSub.broadcast_team_membership(:team_person_removed, %{
        team_uuid: deleted.team_uuid,
        staff_person_uuid: deleted.staff_person_uuid,
        uuid: deleted.uuid
      })

      {:ok, deleted}
    end
  end

  def remove_team_person(team_uuid, staff_person_uuid) do
    case repo().get_by(TeamMembership, team_uuid: team_uuid, staff_person_uuid: staff_person_uuid) do
      nil -> {:error, :not_found}
      tm -> remove_team_person(tm)
    end
  end

  @doc "People not already on this team (for the add-to-team picker)."
  def people_not_on_team(team_uuid) do
    person_uuids_on_team =
      from(tm in TeamMembership,
        where: tm.team_uuid == ^team_uuid,
        select: tm.staff_person_uuid
      )

    from(p in Person,
      where: p.uuid not in subquery(person_uuids_on_team),
      preload: [:user],
      order_by: [asc: p.inserted_at]
    )
    |> repo().all()
  end
end
