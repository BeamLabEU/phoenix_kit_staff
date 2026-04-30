defmodule PhoenixKitStaff.Test.Repo.Migrations.SetupPhoenixKit do
  @moduledoc """
  Test-only schema setup for `phoenix_kit_staff`.

  Mirrors the workspace-wide pattern in `phoenix_kit_locations`,
  `phoenix_kit_hello_world`, etc. — every feature module ships a
  self-contained migration under `test/support/postgres/migrations/`
  that builds exactly the schema it needs to test against, without
  pulling in a parent app or relying on what the host's DB happens
  to have applied.

  The two-stage shape exists because staff's `Person` schema FKs to
  `phoenix_kit_users(uuid)`:

  1. Stage one — `PhoenixKit.Migrations.up()` runs V01..VNN (whichever
     is current on the resolved `phoenix_kit` package). This yields
     `phoenix_kit`, `phoenix_kit_users` (with a UUIDv7 PK by V47+),
     `phoenix_kit_users_tokens`, the role tables, `phoenix_kit_settings`,
     and `phoenix_kit_activities` — all the prereqs Person/Activity
     touch in tests.

  2. Stage two — V100 staff DDL inlined here, since the Hex-published
     `phoenix_kit` (currently `1.7.95`) only ships through V96.
     Wrapped in `IF NOT EXISTS` so that once a release containing
     V100 is published, this migration becomes a no-op.

     The DDL mirrors `phoenix_kit/lib/phoenix_kit/migrations/postgres/v100.ex`
     verbatim. If the production V100 ever changes column shape, this
     migration must follow.
  """

  use Ecto.Migration

  def up do
    # Stage 1 — core PhoenixKit tables.
    PhoenixKit.Migrations.up()

    # Stage 2 — V100 staff tables (identical to
    # PhoenixKit.Migrations.Postgres.V100.up/1, sans prefix support).
    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_staff_departments (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      name VARCHAR(255) NOT NULL,
      description TEXT,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_departments_name_index
    ON phoenix_kit_staff_departments (lower(name))
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_staff_teams (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      department_uuid UUID NOT NULL REFERENCES phoenix_kit_staff_departments(uuid) ON DELETE CASCADE,
      name VARCHAR(255) NOT NULL,
      description TEXT,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_teams_department_name_index
    ON phoenix_kit_staff_teams (department_uuid, lower(name))
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_teams_department_index
    ON phoenix_kit_staff_teams (department_uuid)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_staff_people (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      user_uuid UUID NOT NULL REFERENCES phoenix_kit_users(uuid) ON DELETE CASCADE,
      primary_department_uuid UUID REFERENCES phoenix_kit_staff_departments(uuid) ON DELETE SET NULL,
      status VARCHAR(20) NOT NULL DEFAULT 'active',
      job_title VARCHAR(255),
      employment_type VARCHAR(20),
      employment_start_date DATE,
      employment_end_date DATE,
      work_location VARCHAR(255),
      work_phone VARCHAR(50),
      personal_phone VARCHAR(50),
      bio TEXT,
      skills TEXT,
      notes TEXT,
      date_of_birth DATE,
      personal_email VARCHAR(255),
      emergency_contact_name VARCHAR(255),
      emergency_contact_phone VARCHAR(50),
      emergency_contact_relationship VARCHAR(100),
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_people_user_index
    ON phoenix_kit_staff_people (user_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_people_primary_department_index
    ON phoenix_kit_staff_people (primary_department_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_people_status_index
    ON phoenix_kit_staff_people (status)
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS phoenix_kit_staff_team_memberships (
      uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7(),
      team_uuid UUID NOT NULL REFERENCES phoenix_kit_staff_teams(uuid) ON DELETE CASCADE,
      staff_person_uuid UUID NOT NULL REFERENCES phoenix_kit_staff_people(uuid) ON DELETE CASCADE,
      inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_staff_team_memberships_team_person_index
    ON phoenix_kit_staff_team_memberships (team_uuid, staff_person_uuid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS phoenix_kit_staff_team_memberships_person_index
    ON phoenix_kit_staff_team_memberships (staff_person_uuid)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS phoenix_kit_staff_team_memberships")
    execute("DROP TABLE IF EXISTS phoenix_kit_staff_people")
    execute("DROP TABLE IF EXISTS phoenix_kit_staff_teams")
    execute("DROP TABLE IF EXISTS phoenix_kit_staff_departments")

    PhoenixKit.Migrations.down()
  end
end
