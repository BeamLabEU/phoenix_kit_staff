defmodule PhoenixKitStaff.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Migrations

  @tables ~w(
    phoenix_kit_staff_departments
    phoenix_kit_staff_teams
    phoenix_kit_staff_people
    phoenix_kit_staff_team_memberships
    phoenix_kit_staff_skills
    phoenix_kit_staff_person_skills
    phoenix_kit_staff_employments
  )

  # Every index the chain owns, constraint-backed ones excluded. The "guarded"
  # test below only scans statements that exist, so without this list all of
  # them could be deleted and it would still pass.
  @indexes ~w(
    phoenix_kit_staff_departments_name_index
    phoenix_kit_staff_teams_department_index
    phoenix_kit_staff_teams_department_name_index
    phoenix_kit_staff_people_active_dob_index
    phoenix_kit_staff_people_primary_department_index
    phoenix_kit_staff_people_status_index
    phoenix_kit_staff_people_user_index
    phoenix_kit_staff_team_memberships_person_index
    phoenix_kit_staff_team_memberships_team_person_index
    phoenix_kit_staff_skills_lower_name_index
    phoenix_kit_staff_person_skills_person_skill_index
    phoenix_kit_staff_person_skills_skill_index
    phoenix_kit_staff_employments_one_open_index
    phoenix_kit_staff_employments_person_index
  )

  # 7 primary keys, 10 foreign keys.
  @constraints ~w(
    phoenix_kit_staff_departments_pkey
    phoenix_kit_staff_teams_pkey
    phoenix_kit_staff_people_pkey
    phoenix_kit_staff_team_memberships_pkey
    phoenix_kit_staff_skills_pkey
    phoenix_kit_staff_person_skills_pkey
    phoenix_kit_staff_employments_pkey
    phoenix_kit_staff_teams_department_uuid_fkey
    phoenix_kit_staff_people_primary_department_uuid_fkey
    phoenix_kit_staff_people_user_uuid_fkey
    phoenix_kit_staff_team_memberships_staff_person_uuid_fkey
    phoenix_kit_staff_team_memberships_team_uuid_fkey
    phoenix_kit_staff_person_skills_skill_uuid_fkey
    phoenix_kit_staff_person_skills_staff_person_uuid_fkey
    phoenix_kit_staff_employments_primary_department_uuid_fkey
    phoenix_kit_staff_employments_primary_team_uuid_fkey
    phoenix_kit_staff_employments_staff_person_uuid_fkey
  )

  test "chain is V1 and marks phoenix_kit_staff_people" do
    assert Migrations.current_version() == 1
    assert Migrations.version_table() == "phoenix_kit_staff_people"
  end

  test "the module registers the chain" do
    assert PhoenixKitStaff.migration_module() == Migrations
  end

  test "up_statements creates every owned table idempotently and stamps the marker" do
    stmts = Migrations.up_statements("public")

    for t <- @tables do
      assert Enum.any?(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{t} (")),
             "missing CREATE TABLE for #{t}"
    end

    assert Enum.count(stmts, &(&1 =~ ~r/CREATE TABLE/)) == length(@tables)

    assert List.last(stmts) ==
             "COMMENT ON TABLE public.phoenix_kit_staff_people IS 'pkstf_schema:1'"
  end

  test "up_statements/2 defaults target to current_version/0 and clamps above it" do
    assert Migrations.up_statements("public") == Migrations.up_statements("public", 1)
    assert Migrations.up_statements("public", 99) == Migrations.up_statements("public", 1)
  end

  test "no statement can destroy data, in either direction" do
    all = Migrations.up_statements("public") ++ Migrations.down_statements("public", 0)

    for s <- all do
      # FK referential actions are copied verbatim from core, not destructive
      # statements.
      scanned =
        Regex.replace(~r/ON DELETE (CASCADE|RESTRICT|SET NULL|SET DEFAULT|NO ACTION)/i, s, "")

      refute scanned =~ ~r/\b(DROP|TRUNCATE|DELETE)\b/i, "destructive statement: #{s}"
    end
  end

  test "every CREATE INDEX and constraint is guarded" do
    for s <- Migrations.up_statements("public"), s =~ ~r/CREATE (UNIQUE )?INDEX/ do
      assert s =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/
    end

    for s <- Migrations.up_statements("public"), s =~ ~r/ADD CONSTRAINT/ do
      assert s =~ ~r/DO \$\$/ and s =~ ~r/IF NOT EXISTS/
    end
  end

  test "every pinned index name appears inside a CREATE ... IF NOT EXISTS statement" do
    stmts = Migrations.up_statements("public")

    for name <- @indexes do
      assert Enum.any?(stmts, &(&1 =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS #{name}\b/)),
             "missing guarded index #{name}"
    end

    assert length(@indexes) ==
             Enum.count(stmts, &(&1 =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/))
  end

  test "every pinned constraint name appears inside a guarded DO $$ block" do
    stmts = Migrations.up_statements("public")

    for name <- @constraints do
      assert Enum.any?(stmts, fn s -> s =~ ~r/DO \$\$/ and s =~ ~r/ADD CONSTRAINT #{name}\b/ end),
             "missing guarded constraint #{name}"
    end

    assert length(@constraints) == Enum.count(stmts, &(&1 =~ ~r/DO \$\$/))
  end

  test "the guard checks the same table and schema the constraint is added to" do
    for s <- Migrations.up_statements("tenant_a"), s =~ ~r/DO \$\$/ do
      [_, name] = Regex.run(~r/c\.conname = '([^']+)'/, s)
      [_, table] = Regex.run(~r/t\.relname = '([^']+)'/, s)

      assert s =~ "n.nspname = 'tenant_a'"
      assert s =~ "ALTER TABLE tenant_a.#{table} ADD CONSTRAINT #{name} "
    end
  end

  test "each foreign key keeps core's delete action" do
    stmts = Migrations.up_statements("public")

    for {name, action} <- [
          {"phoenix_kit_staff_teams_department_uuid_fkey", "CASCADE"},
          {"phoenix_kit_staff_people_primary_department_uuid_fkey", "SET NULL"},
          {"phoenix_kit_staff_people_user_uuid_fkey", "CASCADE"},
          {"phoenix_kit_staff_team_memberships_staff_person_uuid_fkey", "CASCADE"},
          {"phoenix_kit_staff_team_memberships_team_uuid_fkey", "CASCADE"},
          {"phoenix_kit_staff_person_skills_skill_uuid_fkey", "CASCADE"},
          {"phoenix_kit_staff_person_skills_staff_person_uuid_fkey", "CASCADE"},
          {"phoenix_kit_staff_employments_primary_department_uuid_fkey", "SET NULL"},
          {"phoenix_kit_staff_employments_primary_team_uuid_fkey", "SET NULL"},
          {"phoenix_kit_staff_employments_staff_person_uuid_fkey", "CASCADE"}
        ] do
      [fk] = Enum.filter(stmts, &(&1 =~ "ADD CONSTRAINT #{name} FOREIGN KEY"))
      assert fk =~ "ON DELETE #{action}", "#{name} should be ON DELETE #{action}"
    end
  end

  test "a prefix is threaded through tables, FK targets and the uuid default" do
    joined = Enum.join(Migrations.up_statements("tenant_a"), "\n")

    refute joined =~ "public."
    assert joined =~ "DEFAULT tenant_a.uuid_generate_v7()"
    assert joined =~ "REFERENCES tenant_a.phoenix_kit_staff_departments(uuid)"
    assert joined =~ "REFERENCES tenant_a.phoenix_kit_staff_people(uuid)"
    assert joined =~ "REFERENCES tenant_a.phoenix_kit_staff_skills(uuid)"
    assert joined =~ "REFERENCES tenant_a.phoenix_kit_staff_teams(uuid)"
    assert joined =~ "REFERENCES tenant_a.phoenix_kit_users(uuid)"
    assert joined =~ "COMMENT ON TABLE tenant_a.phoenix_kit_staff_people IS 'pkstf_schema:1'"
  end

  test "down only rewrites the marker" do
    assert Migrations.down_statements("public", 0) ==
             ["COMMENT ON TABLE public.phoenix_kit_staff_people IS NULL"]

    assert Migrations.down_statements("public", 1) ==
             ["COMMENT ON TABLE public.phoenix_kit_staff_people IS 'pkstf_schema:1'"]
  end

  test "prefix is validated before it reaches DDL" do
    assert_raise ArgumentError, fn -> Migrations.up_statements("public; DROP") end
    assert_raise ArgumentError, fn -> Migrations.down_statements("x'y", 0) end
    assert_raise ArgumentError, fn -> Migrations.migrated_version_runtime(prefix: "a b") end
  end
end
