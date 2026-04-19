# Test helper for PhoenixKitStaff.
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests (tagged `:integration` via PhoenixKitStaff.DataCase)
#          require PostgreSQL — automatically excluded when the database
#          is unavailable.
#
# To enable integration tests:
#   createdb phoenix_kit_staff_test

# Support files are loaded explicitly here rather than compiled via
# elixirc_paths — Elixir 1.19's mix test does not expose `test/support`
# beams to the test compiler in every configuration.
Code.require_file("support/test_repo.ex", __DIR__)
Code.require_file("support/data_case.ex", __DIR__)

alias PhoenixKitStaff.Test.Repo, as: TestRepo

db_config = Application.get_env(:phoenix_kit_staff, TestRepo, [])
db_name = db_config[:database] || "phoenix_kit_staff_test"

db_check =
  case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
    {output, 0} ->
      exists =
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line |> String.split("|") |> List.first("") |> String.trim() == db_name
        end)

      if exists, do: :exists, else: :not_found

    _ ->
      :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""

      Test database "#{db_name}" not found — integration tests excluded.
      Run: createdb #{db_name}
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Run PhoenixKit's full migration suite (V1..V101). That gives us
      # phoenix_kit_users, phoenix_kit_settings, and the V100 staff tables
      # without reimplementing any schema here.
      defmodule PhoenixKitStaff.Test.SetupMigration do
        use Ecto.Migration
        def up, do: PhoenixKit.Migrations.up()
        def down, do: PhoenixKit.Migrations.down()
      end

      Ecto.Migrator.up(TestRepo, 1, PhoenixKitStaff.Test.SetupMigration, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name}
          Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name}
          Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_staff, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the context layer.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

exclude = if repo_available, do: [], else: [:integration]
ExUnit.start(exclude: exclude)
