defmodule PhoenixKitStaff.Integration.MigrationsUpGuardTest do
  @moduledoc """
  `Migrations.up/1` leaves a database already past its target as it is.

  Projects runs this chain before its own (its foreign keys point at staff's
  tables), so on a fresh install staff can be at its current version before
  the host's own, older staff migration file runs. That file must not lower
  the marker. The chain runs for real, through an `Ecto.Migration` runner,
  into a scratch schema; the DDL rolls back with the sandbox transaction.
  """

  use PhoenixKitStaff.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitStaff.Migrations

  @prefix "pkstf_up_guard"

  defmodule Up do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(Process.get(:pkstf_up_opts))
  end

  # One migration that queues a marker and then calls `up/1`, the shape of a
  # chain that ran earlier in the same migration file: nothing it queued has
  # reached the database when `up/1` reads the marker unless `up/1` flushes.
  defmodule QueuedThenUp do
    @moduledoc false
    use Ecto.Migration

    def up do
      execute(Process.get(:pkstf_queued_sql))
      Migrations.up(Process.get(:pkstf_up_opts))
    end
  end

  defp run_up(opts, module \\ Up) do
    Process.put(:pkstf_up_opts, opts)
    Runner.run(Repo, Repo.config(), 1, module, :forward, :up, :up, log: false)
  end

  defp marker_sql(version) do
    "COMMENT ON TABLE #{@prefix}.phoenix_kit_staff_people IS 'pkstf_schema:#{version}'"
  end

  defp marker do
    %{rows: [[comment]]} =
      Repo.query!("SELECT obj_description('#{@prefix}.phoenix_kit_staff_people'::regclass)")

    comment
  end

  setup do
    Repo.query!("CREATE SCHEMA #{@prefix}")

    Repo.query!("""
    CREATE FUNCTION #{@prefix}.uuid_generate_v7() RETURNS uuid
    LANGUAGE sql AS 'SELECT public.uuid_generate_v7()'
    """)

    Repo.query!(
      "CREATE TABLE #{@prefix}.phoenix_kit_users (LIKE public.phoenix_kit_users INCLUDING ALL)"
    )

    :ok
  end

  test "an older target does not lower the marker of a newer database" do
    run_up(prefix: @prefix)
    assert marker() == "pkstf_schema:#{Migrations.current_version()}"

    # A later release's marker: what the database holds when a dependent
    # module brought staff current before the host's old staff file runs.
    newer = Migrations.current_version() + 1
    Repo.query!(marker_sql(newer))

    run_up(prefix: @prefix, version: 1)

    assert marker() == "pkstf_schema:#{newer}"
  end

  # `up_statements/2` clamps a target past this code's chain down to
  # `current_version/0`, so the marker it writes is the clamped one. A database
  # ahead of the code must survive that too, or a downgraded release lowers it.
  test "a target past this code's chain does not lower a newer database's marker" do
    run_up(prefix: @prefix)

    newer = Migrations.current_version() + 1
    Repo.query!(marker_sql(newer))

    run_up(prefix: @prefix, version: newer + 1)

    assert marker() == "pkstf_schema:#{newer}"
  end

  test "a target past this code's chain still stamps the version the code has" do
    run_up(prefix: @prefix, version: Migrations.current_version() + 5)

    assert marker() == "pkstf_schema:#{Migrations.current_version()}"
  end

  test "work queued earlier in the same migration is seen before the marker is read" do
    run_up(prefix: @prefix)

    newer = Migrations.current_version() + 1
    Process.put(:pkstf_queued_sql, marker_sql(newer))

    run_up([prefix: @prefix, version: 1], QueuedThenUp)

    assert marker() == "pkstf_schema:#{newer}"
  end

  test "a target this code has no step for is refused even on a newer database" do
    run_up(prefix: @prefix)

    assert_raise FunctionClauseError, fn -> run_up(prefix: @prefix, version: 0) end
  end

  test "the same target still replays" do
    run_up(prefix: @prefix, version: 1)
    run_up(prefix: @prefix, version: 1)
    assert marker() == "pkstf_schema:1"
  end
end
