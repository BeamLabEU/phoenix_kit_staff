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

  defp run_up(opts) do
    Process.put(:pkstf_up_opts, opts)
    Runner.run(Repo, Repo.config(), 1, Up, :forward, :up, :up, log: false)
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
    Repo.query!("COMMENT ON TABLE #{@prefix}.phoenix_kit_staff_people IS 'pkstf_schema:#{newer}'")

    run_up(prefix: @prefix, version: 1)

    assert marker() == "pkstf_schema:#{newer}"
  end

  test "the same target still replays" do
    run_up(prefix: @prefix, version: 1)
    run_up(prefix: @prefix, version: 1)
    assert marker() == "pkstf_schema:1"
  end
end
