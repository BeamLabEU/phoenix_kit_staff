defmodule PhoenixKitStaff.ActivityLogRescueTest do
  @moduledoc """
  Pins the canonical rescue shape on `PhoenixKitStaff.Activity.log/2`:

      rescue
        Postgrex.Error -> :ok
        DBConnection.OwnershipError -> :ok
        e -> Logger.warning(...)
      catch
        :exit, _ -> :ok

  Without `Postgrex.Error -> :ok` the wrapper would log a `Logger.warning`
  every time an async PubSub broadcast crossed into the logging path
  while the activities table was missing or the sandbox was shutting
  down — exactly the noise the post-Apr canonical rescue suppresses.

  Runs `async: false` because it DROPs `phoenix_kit_activities` inside
  the sandboxed transaction; sandbox rolls the DROP back at test exit
  but parallel async tests against the same table would deadlock.
  """

  use PhoenixKitStaff.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitStaff.Activity
  alias PhoenixKitStaff.Test.Repo, as: TestRepo

  test "wrapper does not emit its own [Staff] warning on routine Postgrex.Error" do
    # Drop inside the sandbox transaction; rolls back on test exit.
    TestRepo.query!("DROP TABLE phoenix_kit_activities CASCADE")

    log =
      capture_log([level: :warning], fn ->
        # The wrapper must not crash; result is either `:ok` (if the
        # rescue clause caught a raise) or core's `{:error, _}` tuple.
        result =
          Activity.log("staff.test_action",
            actor_uuid: Ecto.UUID.generate(),
            resource_type: "staff_person",
            resource_uuid: Ecto.UUID.generate(),
            metadata: %{}
          )

        assert match?(:ok, result) or match?({:error, _}, result)
      end)

    # Core's own `PhoenixKit.Activity.log/1` rescue logs "Activity
    # logging error: ..." independently — that's pre-existing upstream
    # noise, out of scope for this wrapper. What we pin: the staff
    # wrapper's own `[Staff] Activity logging error: ...` message must
    # NOT fire on Postgrex.Error / DBConnection.OwnershipError because
    # those have dedicated `-> :ok` rescue clauses ahead of the generic
    # `e ->` Logger.warning branch.
    refute log =~ "[Staff] Activity logging error",
           "the wrapper's `e -> Logger.warning('[Staff] ...')` branch fired on " <>
             "a Postgrex.Error — the canonical rescue shape requires " <>
             "Postgrex.Error / DBConnection.OwnershipError clauses BEFORE the " <>
             "generic `e ->` clause"
  end

  test "Activity.log/2 with valid table writes a row and is non-crashing" do
    actor_uuid = Ecto.UUID.generate()
    resource_uuid = Ecto.UUID.generate()

    # Core returns `{:ok, %Activity.Entry{}}`; the wrapper passes that
    # through. The contract for callers is "doesn't crash, returns
    # something" — they ignore the return value in production.
    result =
      Activity.log("staff.test_happy_path",
        actor_uuid: actor_uuid,
        resource_type: "staff_person",
        resource_uuid: resource_uuid,
        metadata: %{"k" => "v"}
      )

    assert match?({:ok, _entry}, result) or match?(:ok, result)

    assert_activity_logged("staff.test_happy_path",
      actor_uuid: actor_uuid,
      resource_uuid: resource_uuid,
      metadata_has: %{"k" => "v"}
    )
  end
end
