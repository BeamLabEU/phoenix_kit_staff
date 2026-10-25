defmodule PhoenixKitStaff.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_staff` — the protocol
  core's `mix phoenix_kit.update` discovers through `migration_module/0`:
  `current_version/0`, `migrated_version_runtime/1`, an idempotent `up/1` and a
  version-aware `down/1`. Same shape as `phoenix_kit_locations`' chain.

  ## What V1 is

  An ADOPTION step for the seven tables core's chain creates for this module:
  `phoenix_kit_staff_departments`, `phoenix_kit_staff_teams`, `phoenix_kit_staff_people`, `phoenix_kit_staff_team_memberships`, `phoenix_kit_staff_skills`, `phoenix_kit_staff_person_skills` and `phoenix_kit_staff_employments`. Six of them are core's V135 baseline; `phoenix_kit_staff_employments` is core's V136, the employment history that keeps the matching columns on `phoenix_kit_staff_people` as a mirror of the open span. The statements below re-state what a fresh core install builds today, with core's exact object names.

    * On every existing install the tables are already there: each `CREATE
      TABLE IF NOT EXISTS`, guarded `DO $$ … pg_constraint … $$` block and
      `CREATE INDEX IF NOT EXISTS` finds its target and does nothing. The only
      new object is the `pkstf_schema:1` marker.
    * On an install whose core no longer creates the tables, the same
      statements create them, identical to what core built.
      `test/phoenix_kit_staff/integration/migrations_build_alone_test.exs` proves that against
      core's chain (core's `PhoenixKit.TestSupport.ModuleChainCheck`).

  From V1 on, this chain owns the tables' shape: a change to them is a new
  version here, never a core migration (core enforces that since V223; see
  core's `dev_docs/plans/2026-10-25-module-table-ownership.md`). Until core's
  `ExpectedSchema` manifest hands these tables over, a version that reshapes an
  object the manifest declares must first take it out of the manifest, or
  `mix phoenix_kit.repair` restores the old shape; a version that only adds
  objects the manifest never names needs no core step.

  ## What `down/1` is NOT

  `down/1` rewrites the version marker; it never drops a table. The rows are
  people's employment records, and on every current install core created the
  tables.
  `test/phoenix_kit_staff/migrations_test.exs` pins this by asserting that no
  statement this module can emit matches `DROP`, `TRUNCATE` or `DELETE`.

  ## Adding a version

  1. Append the new statements to `up_statements/2` behind `target >= N`
     (never edit V1's statements: hosts past V1 never re-run them).
  2. Bump `@current_version`.

  The migrated version is a `pkstf_schema:<N>` `COMMENT ON TABLE` marker on
  `phoenix_kit_staff_people`; a table without one reads as version 0 — the shape
  core built before this chain existed.
  """

  use Ecto.Migration

  @current_version 1
  @marker_prefix "pkstf_schema:"
  @version_table "phoenix_kit_staff_people"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkstf_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc "The chain version read from INSIDE a migration (migration repo)."
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)
    %{rows: rows} = repo().query!(marker_query(), [prefix])
    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkstf_schema:<N>` marker when present; a marker-less table
  reads as `0` (core's shape — V1 is purely adoptive, there is no pre-chain
  content to defend).

  `catch :exit` matters as much as `rescue`: a dead or unstarted pool exits
  rather than raising, and `mix phoenix_kit.status` calls this across every
  installed module.
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed").
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)

    target =
      if is_list(opts), do: Keyword.get(opts, :version, @current_version), else: @current_version

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops a table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS` / guarded `DO $$` block /
  `COMMENT`), so it is safe to replay on an install where core already created
  the tables and on one with none of them.

  V1 order: every `CREATE TABLE`, then every constraint guard (primary keys,
  then foreign keys), then every index, then the version marker last. The
  foreign-key guards run after every table exists.

  `target` selects how much of the chain to emit (default `current_version/0`);
  the wrapper migration core's update task generates passes an explicit
  `:version`, and a stale wrapper asking for an older version must not receive
  a newer version's objects.
  """
  @spec up_statements(String.t(), pos_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 1 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."
    target = min(target, @current_version)

    List.flatten([
      v1_statements(prefix, p),
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
    ])
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  # ── V1: adoption of the tables core's chain creates ─────────────────────

  defp v1_statements(prefix, p) do
    [tables(p), constraints(prefix, p), indexes(p)]
  end

  # Columns, types, defaults and order as a fresh core install builds them
  # (V135's six tables, then V136's employments).
  defp tables(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_departments (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "name" character varying(255) NOT NULL,
        "description" text,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "translations" jsonb DEFAULT '{}'::jsonb NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_teams (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "department_uuid" uuid NOT NULL,
        "name" character varying(255) NOT NULL,
        "description" text,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "translations" jsonb DEFAULT '{}'::jsonb NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_people (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "user_uuid" uuid NOT NULL,
        "primary_department_uuid" uuid,
        "status" character varying(20) DEFAULT 'active'::character varying NOT NULL,
        "job_title" character varying(255),
        "employment_type" character varying(20),
        "employment_start_date" date,
        "employment_end_date" date,
        "work_location" character varying(255),
        "work_phone" character varying(50),
        "personal_phone" character varying(50),
        "bio" text,
        "notes" text,
        "date_of_birth" date,
        "personal_email" character varying(255),
        "emergency_contact_name" character varying(255),
        "emergency_contact_phone" character varying(50),
        "emergency_contact_relationship" character varying(100),
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
        "translations" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "name" character varying,
        "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_team_memberships (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "team_uuid" uuid NOT NULL,
        "staff_person_uuid" uuid NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_skills (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "name" character varying(255) NOT NULL,
        "description" text,
        "translations" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "levels" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "allow_multiple_levels" boolean DEFAULT false NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_person_skills (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "staff_person_uuid" uuid NOT NULL,
        "skill_uuid" uuid NOT NULL,
        "proficiency_levels" jsonb DEFAULT '[]'::jsonb NOT NULL,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_staff_employments (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "staff_person_uuid" uuid NOT NULL,
        "employment_type" character varying(50),
        "job_title" character varying(255),
        "translations" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "primary_department_uuid" uuid,
        "primary_team_uuid" uuid,
        "employment_start_date" date,
        "employment_end_date" date,
        "work_location" character varying(255),
        "notes" text,
        "inserted_at" timestamp with time zone DEFAULT now() NOT NULL,
        "updated_at" timestamp with time zone DEFAULT now() NOT NULL
      )
      """
    ]
  end

  # Core's constraint names (Ecto's defaults in V135 and V136).
  defp constraints(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_departments",
        "phoenix_kit_staff_departments_pkey",
        "ALTER TABLE #{p}phoenix_kit_staff_departments ADD CONSTRAINT phoenix_kit_staff_departments_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_teams",
        "phoenix_kit_staff_teams_pkey",
        "ALTER TABLE #{p}phoenix_kit_staff_teams ADD CONSTRAINT phoenix_kit_staff_teams_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_people",
        "phoenix_kit_staff_people_pkey",
        "ALTER TABLE #{p}phoenix_kit_staff_people ADD CONSTRAINT phoenix_kit_staff_people_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_team_memberships",
        "phoenix_kit_staff_team_memberships_pkey",
        "ALTER TABLE #{p}phoenix_kit_staff_team_memberships ADD CONSTRAINT phoenix_kit_staff_team_memberships_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_skills",
        "phoenix_kit_staff_skills_pkey",
        "ALTER TABLE #{p}phoenix_kit_staff_skills ADD CONSTRAINT phoenix_kit_staff_skills_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_person_skills",
        "phoenix_kit_staff_person_skills_pkey",
        "ALTER TABLE #{p}phoenix_kit_staff_person_skills ADD CONSTRAINT phoenix_kit_staff_person_skills_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_employments",
        "phoenix_kit_staff_employments_pkey",
        "ALTER TABLE #{p}phoenix_kit_staff_employments ADD CONSTRAINT phoenix_kit_staff_employments_pkey PRIMARY KEY (uuid)"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_teams",
        "phoenix_kit_staff_teams_department_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_teams ADD CONSTRAINT phoenix_kit_staff_teams_department_uuid_fkey FOREIGN KEY (department_uuid) REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_people",
        "phoenix_kit_staff_people_primary_department_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_people ADD CONSTRAINT phoenix_kit_staff_people_primary_department_uuid_fkey FOREIGN KEY (primary_department_uuid) REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_people",
        "phoenix_kit_staff_people_user_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_people ADD CONSTRAINT phoenix_kit_staff_people_user_uuid_fkey FOREIGN KEY (user_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_team_memberships",
        "phoenix_kit_staff_team_memberships_staff_person_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_team_memberships ADD CONSTRAINT phoenix_kit_staff_team_memberships_staff_person_uuid_fkey FOREIGN KEY (staff_person_uuid) REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_team_memberships",
        "phoenix_kit_staff_team_memberships_team_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_team_memberships ADD CONSTRAINT phoenix_kit_staff_team_memberships_team_uuid_fkey FOREIGN KEY (team_uuid) REFERENCES #{p}phoenix_kit_staff_teams(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_person_skills",
        "phoenix_kit_staff_person_skills_skill_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_person_skills ADD CONSTRAINT phoenix_kit_staff_person_skills_skill_uuid_fkey FOREIGN KEY (skill_uuid) REFERENCES #{p}phoenix_kit_staff_skills(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_person_skills",
        "phoenix_kit_staff_person_skills_staff_person_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_person_skills ADD CONSTRAINT phoenix_kit_staff_person_skills_staff_person_uuid_fkey FOREIGN KEY (staff_person_uuid) REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_employments",
        "phoenix_kit_staff_employments_primary_department_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_employments ADD CONSTRAINT phoenix_kit_staff_employments_primary_department_uuid_fkey FOREIGN KEY (primary_department_uuid) REFERENCES #{p}phoenix_kit_staff_departments(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_employments",
        "phoenix_kit_staff_employments_primary_team_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_employments ADD CONSTRAINT phoenix_kit_staff_employments_primary_team_uuid_fkey FOREIGN KEY (primary_team_uuid) REFERENCES #{p}phoenix_kit_staff_teams(uuid) ON DELETE SET NULL"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_staff_employments",
        "phoenix_kit_staff_employments_staff_person_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_staff_employments ADD CONSTRAINT phoenix_kit_staff_employments_staff_person_uuid_fkey FOREIGN KEY (staff_person_uuid) REFERENCES #{p}phoenix_kit_staff_people(uuid) ON DELETE CASCADE"
      )
    ]
  end

  # Index names are core's. They stay bare on CREATE (an index lives in its
  # table's schema).
  defp indexes(p) do
    [
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_departments_name_index ON #{p}phoenix_kit_staff_departments USING btree (lower((name)::text))",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_staff_teams_department_index ON #{p}phoenix_kit_staff_teams USING btree (department_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_teams_department_name_index ON #{p}phoenix_kit_staff_teams USING btree (department_uuid, lower((name)::text))",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_staff_people_active_dob_index ON #{p}phoenix_kit_staff_people USING btree (date_of_birth) WHERE (((status)::text = 'active'::text) AND (date_of_birth IS NOT NULL))",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_staff_people_primary_department_index ON #{p}phoenix_kit_staff_people USING btree (primary_department_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_staff_people_status_index ON #{p}phoenix_kit_staff_people USING btree (status)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_people_user_index ON #{p}phoenix_kit_staff_people USING btree (user_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_staff_team_memberships_person_index ON #{p}phoenix_kit_staff_team_memberships USING btree (staff_person_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_team_memberships_team_person_index ON #{p}phoenix_kit_staff_team_memberships USING btree (team_uuid, staff_person_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_skills_lower_name_index ON #{p}phoenix_kit_staff_skills USING btree (lower((name)::text))",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_person_skills_person_skill_index ON #{p}phoenix_kit_staff_person_skills USING btree (staff_person_uuid, skill_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_staff_person_skills_skill_index ON #{p}phoenix_kit_staff_person_skills USING btree (skill_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_employments_one_open_index ON #{p}phoenix_kit_staff_employments USING btree (staff_person_uuid) WHERE (employment_end_date IS NULL)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_staff_employments_person_index ON #{p}phoenix_kit_staff_employments USING btree (staff_person_uuid)"
    ]
  end

  defp guarded_constraint(prefix, table, constraint_name, add_sql) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        #{add_sql};
      END IF;
    END
    $$
    """
  end

  defp marker_query do
    """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL and into the guard blocks' string literals.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
