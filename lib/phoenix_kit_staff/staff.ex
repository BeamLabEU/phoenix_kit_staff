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

  # Soft-delete sentinel, mirrors `Person.soft_delete_status/0`. Defined
  # here too so it's usable in guards and compile-time query pins.
  @soft_delete_status "trashed"

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @doc "Returns the regex used to validate emails throughout the staff module."
  @spec email_regex() :: Regex.t()
  def email_regex, do: @email_regex

  @doc "Whether the given string looks like a valid email."
  @spec valid_email?(any()) :: boolean()
  def valid_email?(email) when is_binary(email), do: String.match?(email, @email_regex)
  def valid_email?(_), do: false

  # ── Rename placeholder user email ───────────────────────────────────

  @doc """
  Renames the email of an unclaimed placeholder user directly in place.
  Safe only for users we created via `find_or_create_user_by_email/1`
  that nobody has signed up for yet. Refuses if another user already
  exists with the new email.
  """
  @spec rename_placeholder_email(User.t(), String.t()) ::
          :ok
          | {:ok, User.t()}
          | {:error, PhoenixKitStaff.Errors.error_atom() | Ecto.Changeset.t()}
  def rename_placeholder_email(%User{} = user, new_email) do
    new_email = String.trim(new_email)
    current = user.email

    cond do
      new_email == "" ->
        {:error, :blank_email}

      new_email == current ->
        :ok

      not placeholder?(user) ->
        {:error, :placeholder_already_claimed}

      Auth.get_user_by_email(new_email) != nil ->
        {:error, :email_already_taken}

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
  @spec find_or_create_user_by_email(String.t()) ::
          {:ok, User.t(), :created | :existing}
          | {:error, PhoenixKitStaff.Errors.error_atom() | Ecto.Changeset.t()}
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
  @spec eligible_users(keyword()) :: [User.t()]
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

  @doc """
  Lists people. Accepts `:preload`, `:status` filter, `:search` (matches
  name or user email), and `:include_trashed` (default `false`).

  Trashed (soft-deleted) people are **excluded by default**. Pass
  `status: "trashed"` for the Trash view, or `include_trashed: true` to
  list everything regardless of status.
  """
  @spec list_people(keyword()) :: [Person.t()]
  def list_people(opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])
    status = Keyword.get(opts, :status)
    include_trashed = Keyword.get(opts, :include_trashed, false)
    search = opts |> Keyword.get(:search) |> normalize_search()

    Person
    |> scope_status(status, include_trashed)
    |> maybe_filter_search(search)
    |> order_by([p], asc: p.status, desc: p.inserted_at)
    |> preload(^preload)
    |> repo().all()
  end

  # Status scoping with trashed-exclusion by default:
  #   * "trashed"           → only trashed (the Trash view)
  #   * "active"/"inactive" → that status (inherently excludes trashed)
  #   * nil/"" + include?   → everything
  #   * nil/"" (default)    → everything except trashed
  defp scope_status(query, @soft_delete_status, _include),
    do: where(query, [p], p.status == ^@soft_delete_status)

  defp scope_status(query, status, _include) when status in ["active", "inactive"],
    do: where(query, [p], p.status == ^status)

  defp scope_status(query, _blank, true), do: query

  defp scope_status(query, _blank, false),
    do: where(query, [p], p.status != ^@soft_delete_status)

  defp maybe_filter_search(query, nil), do: query

  defp maybe_filter_search(query, term) do
    like = "%#{term}%"

    from(p in query,
      join: u in assoc(p, :user),
      where: ilike(u.email, ^like) or ilike(p.name, ^like)
    )
  end

  defp normalize_search(nil), do: nil
  defp normalize_search(""), do: nil
  defp normalize_search(s) when is_binary(s), do: String.trim(s)

  @doc "Fetches a person by the linked user's uuid, or `nil` if no staff profile exists."
  @spec get_person_by_user_uuid(UUIDv7.t() | String.t(), keyword()) :: Person.t() | nil
  def get_person_by_user_uuid(user_uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> where([p], p.user_uuid == ^user_uuid)
    |> preload(^preload)
    |> repo().one()
  end

  @doc "Fetches a person by uuid. Raises if not found."
  @spec get_person!(UUIDv7.t() | String.t(), keyword()) :: Person.t()
  def get_person!(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> preload(^preload)
    |> repo().get!(uuid)
  end

  @doc "Fetches a person by uuid, or `nil` if not found."
  @spec get_person(UUIDv7.t() | String.t() | any(), keyword()) :: Person.t() | nil
  def get_person(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> preload(^preload)
    |> repo().get(uuid)
  end

  @doc "Returns a changeset for the given person."
  @spec change_person(Person.t(), map()) :: Ecto.Changeset.t(Person.t())
  def change_person(%Person{} = p, attrs \\ %{}), do: Person.changeset(p, attrs)

  @doc """
  Inserts a person and broadcasts `:person_created` on success.

  Guards the strict 1:1 `user_uuid` unique constraint against a confusing
  failure: if the target user already has a **trashed** staff profile,
  re-adding them would trip the unique index. Instead this returns
  `{:error, {:trashed_person_exists, trashed_person}}` so the caller can
  offer to restore the existing record rather than creating a duplicate.
  """
  @spec create_person(map()) ::
          {:ok, Person.t()}
          | {:error, Ecto.Changeset.t(Person.t())}
          | {:error, {:trashed_person_exists, Person.t()}}
  def create_person(attrs) do
    case trashed_person_for_user(user_uuid_from(attrs)) do
      %Person{} = trashed ->
        {:error, {:trashed_person_exists, trashed}}

      nil ->
        with {:ok, person} <- %Person{} |> Person.changeset(attrs) |> repo().insert() do
          StaffPubSub.broadcast_person(:person_created, %{uuid: person.uuid})
          {:ok, person}
        end
    end
  end

  defp user_uuid_from(attrs), do: attrs["user_uuid"] || attrs[:user_uuid]

  defp trashed_person_for_user(nil), do: nil

  defp trashed_person_for_user(user_uuid) do
    Person
    |> where([p], p.user_uuid == ^user_uuid and p.status == ^@soft_delete_status)
    |> repo().one()
  end

  @doc "Updates a person and broadcasts `:person_updated` on success."
  @spec update_person(Person.t(), map()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  def update_person(%Person{} = p, attrs) do
    with {:ok, updated} <- p |> Person.changeset(attrs) |> repo().update() do
      StaffPubSub.broadcast_person(:person_updated, %{uuid: updated.uuid})
      {:ok, updated}
    end
  end

  @doc """
  Soft-deletes a person: sets `status` to `"trashed"` and stashes the
  prior lifecycle status under `metadata["trashed_from_status"]` so
  `restore_person/1` can return them to active/inactive. Broadcasts
  `:person_updated`. Returns `{:error, :already_trashed}` if it's
  already trashed.

  Project assignments and team memberships are deliberately left intact
  (the FK rows survive), so the person — and their assignments — come
  back cleanly on restore. This is the whole point over hard delete,
  which would silently NULL out project assignments (FK is SET NULL).
  """
  @spec trash_person(Person.t()) ::
          {:ok, Person.t()} | {:error, :already_trashed | Ecto.Changeset.t(Person.t())}
  def trash_person(%Person{status: @soft_delete_status}), do: {:error, :already_trashed}

  def trash_person(%Person{} = p) do
    metadata = Map.put(p.metadata || %{}, "trashed_from_status", p.status)

    with {:ok, updated} <-
           p
           |> Ecto.Changeset.change(status: @soft_delete_status, metadata: metadata)
           |> repo().update() do
      StaffPubSub.broadcast_person(:person_updated, %{uuid: updated.uuid})
      {:ok, updated}
    end
  end

  @doc """
  Restores a trashed person to the status they had before trashing
  (read from `metadata["trashed_from_status"]`, validated against
  `Person.statuses/0`, defaulting to `"active"`). Clears the stash key
  but preserves any other metadata. Broadcasts `:person_updated`.
  Returns `{:error, :not_trashed}` if the person isn't trashed.
  """
  @spec restore_person(Person.t()) ::
          {:ok, Person.t()} | {:error, :not_trashed | Ecto.Changeset.t(Person.t())}
  def restore_person(%Person{status: @soft_delete_status} = p) do
    prior = restore_target_status(p.metadata)
    metadata = Map.delete(p.metadata || %{}, "trashed_from_status")

    with {:ok, updated} <-
           p
           |> Ecto.Changeset.change(status: prior, metadata: metadata)
           |> repo().update() do
      StaffPubSub.broadcast_person(:person_updated, %{uuid: updated.uuid})
      {:ok, updated}
    end
  end

  def restore_person(%Person{}), do: {:error, :not_trashed}

  defp restore_target_status(metadata) do
    case metadata do
      %{"trashed_from_status" => s} -> if s in Person.statuses(), do: s, else: "active"
      _ -> "active"
    end
  end

  @doc """
  Permanently deletes a person (hard `Repo.delete`) and broadcasts
  `:person_deleted`. **Trash-only**: refuses a non-trashed person with
  `{:error, :not_trashed}` so permanent deletion is always a deliberate
  two-step (trash, then delete) — a stray direct call can't nuke an
  active person.

  The rescue clauses guard a *hypothetical* future `ON DELETE RESTRICT`
  FK into `phoenix_kit_staff_people`. Today none exist — the projects
  assignee FK is `ON DELETE SET NULL` and team memberships are
  `ON DELETE CASCADE` — so a delete won't raise; it succeeds and the
  caller is expected to have warned that project-assignment links get
  cleared. The rescue stays as cheap insurance against a future
  restricting consumer.
  """
  @spec delete_person(Person.t()) ::
          {:ok, Person.t()}
          | {:error, :not_trashed | :referenced_by_external | Ecto.Changeset.t(Person.t())}
  def delete_person(%Person{status: @soft_delete_status} = p) do
    with {:ok, deleted} <- repo().delete(p) do
      StaffPubSub.broadcast_person(:person_deleted, %{uuid: deleted.uuid})
      {:ok, deleted}
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.type == :foreign_key,
        do: {:error, :referenced_by_external},
        else: reraise(e, __STACKTRACE__)

    e in Postgrex.Error ->
      if fk_or_not_null_violation?(e),
        do: {:error, :referenced_by_external},
        else: reraise(e, __STACKTRACE__)
  end

  def delete_person(%Person{}), do: {:error, :not_trashed}

  defp fk_or_not_null_violation?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:foreign_key_violation, :not_null_violation]

  defp fk_or_not_null_violation?(_), do: false

  # ── Bulk soft-delete operations ────────────────────────────────────

  @doc """
  Bulk-trashes the given people. Per-row stashes the prior status into
  `metadata["trashed_from_status"]` (in a single UPDATE — the SET
  expressions read the pre-update row, so `status` there is still the
  old value). Skips rows already trashed. Broadcasts one bulk event.
  Returns `{:ok, trashed_count}`.
  """
  @spec bulk_trash([UUIDv7.t() | String.t()]) :: {:ok, non_neg_integer()}
  def bulk_trash(uuids) when is_list(uuids) do
    {count, _} =
      from(p in Person,
        where: p.uuid in ^uuids and p.status != ^@soft_delete_status,
        update: [
          set: [
            status: ^@soft_delete_status,
            metadata:
              fragment(
                "jsonb_set(coalesce(?, '{}'::jsonb), '{trashed_from_status}', to_jsonb(?::text))",
                p.metadata,
                p.status
              ),
            updated_at: ^DateTime.truncate(DateTime.utc_now(), :second)
          ]
        ]
      )
      |> repo().update_all([])

    if count > 0, do: StaffPubSub.broadcast_people_bulk(:person_updated)
    {:ok, count}
  end

  @doc """
  Bulk-restores trashed people to their stashed prior status (validated
  to `active`/`inactive`, else `active`), clearing the stash key.
  Broadcasts one bulk event. Returns `{:ok, restored_count}`.
  """
  @spec bulk_restore([UUIDv7.t() | String.t()]) :: {:ok, non_neg_integer()}
  def bulk_restore(uuids) when is_list(uuids) do
    {count, _} =
      from(p in Person,
        where: p.uuid in ^uuids and p.status == ^@soft_delete_status,
        update: [
          set: [
            status:
              fragment(
                "CASE WHEN (?->>'trashed_from_status') IN ('active','inactive') THEN (?->>'trashed_from_status') ELSE 'active' END",
                p.metadata,
                p.metadata
              ),
            metadata: fragment("(? - 'trashed_from_status')", p.metadata),
            updated_at: ^DateTime.truncate(DateTime.utc_now(), :second)
          ]
        ]
      )
      |> repo().update_all([])

    if count > 0, do: StaffPubSub.broadcast_people_bulk(:person_updated)
    {:ok, count}
  end

  @doc """
  Bulk permanent-deletes people. Broadcasts one bulk event. Returns
  `{:ok, deleted_count}` or `{:error, :referenced_by_external}` if a
  (hypothetical future) RESTRICT FK blocks the delete.
  """
  @spec bulk_delete([UUIDv7.t() | String.t()]) ::
          {:ok, non_neg_integer()} | {:error, :referenced_by_external}
  def bulk_delete(uuids) when is_list(uuids) do
    # Trash-only, same contract as delete_person/1 — active rows in the
    # selection are left untouched.
    {count, _} =
      from(p in Person, where: p.uuid in ^uuids and p.status == ^@soft_delete_status)
      |> repo().delete_all()

    if count > 0, do: StaffPubSub.broadcast_people_bulk(:person_deleted)
    {:ok, count}
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      if match?(%Ecto.ConstraintError{type: :foreign_key}, e) or fk_or_not_null_violation?(e),
        do: {:error, :referenced_by_external},
        else: reraise(e, __STACKTRACE__)
  end

  @doc "Number of non-trashed people (the active roster size)."
  @spec count_people() :: non_neg_integer()
  def count_people do
    from(p in Person, where: p.status != ^@soft_delete_status)
    |> repo().aggregate(:count, :uuid)
  end

  @doc "Number of trashed (soft-deleted) people."
  @spec count_trashed() :: non_neg_integer()
  def count_trashed do
    from(p in Person, where: p.status == ^@soft_delete_status)
    |> repo().aggregate(:count, :uuid)
  end

  # ── Upcoming birthdays ─────────────────────────────────────────────

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

  # ── Org tree ───────────────────────────────────────────────────────

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
    all_people = list_people()

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
  @spec list_team_memberships(UUIDv7.t() | String.t()) :: [TeamMembership.t()]
  def list_team_memberships(team_uuid) do
    TeamMembership
    |> where([tm], tm.team_uuid == ^team_uuid)
    |> preload(staff_person: [:user])
    |> order_by([tm], asc: tm.inserted_at)
    |> repo().all()
  end

  @doc "All memberships a given person belongs to, with team and department preloaded."
  @spec list_memberships_for_person(UUIDv7.t() | String.t()) :: [TeamMembership.t()]
  def list_memberships_for_person(person_uuid) do
    TeamMembership
    |> where([tm], tm.staff_person_uuid == ^person_uuid)
    |> preload(team: [:department])
    |> order_by([tm], asc: tm.inserted_at)
    |> repo().all()
  end

  @doc "Adds a person to a team and broadcasts `:team_person_added`."
  @spec add_team_person(UUIDv7.t() | String.t(), UUIDv7.t() | String.t()) ::
          {:ok, TeamMembership.t()} | {:error, Ecto.Changeset.t(TeamMembership.t())}
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
  @spec remove_team_person(TeamMembership.t()) ::
          {:ok, TeamMembership.t()} | {:error, Ecto.Changeset.t(TeamMembership.t())}
  @spec remove_team_person(UUIDv7.t() | String.t(), UUIDv7.t() | String.t()) ::
          {:ok, TeamMembership.t()}
          | {:error, Ecto.Changeset.t(TeamMembership.t())}
          | {:error, :not_found}
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
  @spec people_not_on_team(UUIDv7.t() | String.t()) :: [Person.t()]
  def people_not_on_team(team_uuid) do
    person_uuids_on_team =
      from(tm in TeamMembership,
        where: tm.team_uuid == ^team_uuid,
        select: tm.staff_person_uuid
      )

    from(p in Person,
      where:
        p.uuid not in subquery(person_uuids_on_team) and
          p.status != ^@soft_delete_status,
      preload: [:user],
      order_by: [asc: p.inserted_at]
    )
    |> repo().all()
  end
end
