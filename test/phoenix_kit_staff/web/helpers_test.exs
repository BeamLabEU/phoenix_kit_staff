defmodule PhoenixKitStaff.Web.HelpersTest do
  @moduledoc """
  Pins `PhoenixKitStaff.Web.Helpers.log_operation_error/3` (Batch 3
  fix-everything pass) — the LV-layer redirect that lands a failure-side
  audit row with `db_pending: true` while preserving the staff
  module's documented success-only `Activity` invariant at the call
  site (catalogue Batch 4 canonical pattern).

  These are unit-style tests against the helper directly with synthetic
  sockets, exercising all three reason shapes (changeset / atom /
  other) and pinning the PII-safe metadata contract: no error message
  values land in metadata, only field-name keys.
  """

  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitStaff.Web.Helpers

  defp socket_with_actor(actor_uuid) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        phoenix_kit_current_user: %{uuid: actor_uuid, email: "actor@example.com"},
        phoenix_kit_current_scope: %Scope{
          user: %{uuid: actor_uuid, email: "actor@example.com"},
          authenticated?: true,
          cached_roles: ["Owner"],
          cached_permissions: MapSet.new(["staff"])
        },
        __changed__: %{}
      }
    }
  end

  describe "changeset reason — error_keys are field names only (PII-safe)" do
    test "lands an activity row with db_pending=true and error_keys" do
      actor_uuid = Ecto.UUID.generate()
      resource_uuid = Ecto.UUID.generate()

      changeset =
        %PhoenixKitStaff.Schemas.Department{}
        |> Ecto.Changeset.cast(%{}, [:name])
        |> Ecto.Changeset.add_error(:name, "can't be blank")
        |> Ecto.Changeset.add_error(:description, "too long")

      Helpers.log_operation_error("staff.department_deleted", socket_with_actor(actor_uuid),
        reason: changeset,
        resource_type: "department",
        resource_uuid: resource_uuid
      )

      row =
        assert_activity_logged("staff.department_deleted",
          actor_uuid: actor_uuid,
          resource_uuid: resource_uuid,
          metadata_has: %{"db_pending" => true, "error_kind" => "changeset"}
        )

      # PII safety: error_keys should be field names only, never the
      # error messages themselves (which can interpolate user input).
      assert row.metadata["error_keys"] == ["name", "description"] or
               row.metadata["error_keys"] == ["description", "name"]

      refute row.metadata["error_keys"] |> Enum.any?(&String.contains?(&1, "can't be blank"))
    end
  end

  describe "atom reason — error_atom landed as string" do
    test "lands an activity row with db_pending and error_atom" do
      actor_uuid = Ecto.UUID.generate()
      resource_uuid = Ecto.UUID.generate()

      Helpers.log_operation_error("staff.team_person_removed", socket_with_actor(actor_uuid),
        reason: :not_found,
        resource_type: "team",
        resource_uuid: resource_uuid,
        target_uuid: Ecto.UUID.generate()
      )

      assert_activity_logged("staff.team_person_removed",
        actor_uuid: actor_uuid,
        resource_uuid: resource_uuid,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "atom",
          "error_atom" => "not_found"
        }
      )
    end
  end

  describe "other reason — error_kind = \"other\", no value leak" do
    test "lands an activity row with error_kind=other and no leaked detail" do
      actor_uuid = Ecto.UUID.generate()
      resource_uuid = Ecto.UUID.generate()

      Helpers.log_operation_error("staff.person_deleted", socket_with_actor(actor_uuid),
        reason: %RuntimeError{message: "secret leak attempt"},
        resource_type: "staff_person",
        resource_uuid: resource_uuid
      )

      row =
        assert_activity_logged("staff.person_deleted",
          actor_uuid: actor_uuid,
          resource_uuid: resource_uuid,
          metadata_has: %{"db_pending" => true, "error_kind" => "other"}
        )

      # The reason struct should never make it into metadata.
      refute row.metadata |> Map.values() |> Enum.any?(&match?(%RuntimeError{}, &1))
      refute row.metadata |> inspect() =~ "secret leak attempt"
    end
  end

  describe "extra metadata merging" do
    test "user-supplied metadata merges alongside helper's defaults" do
      actor_uuid = Ecto.UUID.generate()
      resource_uuid = Ecto.UUID.generate()

      Helpers.log_operation_error("staff.department_deleted", socket_with_actor(actor_uuid),
        reason: :forbidden,
        resource_type: "department",
        resource_uuid: resource_uuid,
        metadata: %{"name" => "Engineering"}
      )

      assert_activity_logged("staff.department_deleted",
        resource_uuid: resource_uuid,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "atom",
          "error_atom" => "forbidden",
          "name" => "Engineering"
        }
      )
    end

    test "helper-owned keys win over caller-supplied collisions" do
      # Audit-feed readers depend on `db_pending` and `error_kind`
      # being authoritative — a buggy caller passing a colliding key
      # must NOT poison those keys. Pins the merge precedence
      # introduced after PR #3 review.
      actor_uuid = Ecto.UUID.generate()
      resource_uuid = Ecto.UUID.generate()

      Helpers.log_operation_error("staff.team_deleted", socket_with_actor(actor_uuid),
        reason: :forbidden,
        resource_type: "team",
        resource_uuid: resource_uuid,
        metadata: %{
          "db_pending" => false,
          "error_kind" => "wrong",
          "error_atom" => "wrong",
          "safe_extra" => "kept"
        }
      )

      row =
        assert_activity_logged("staff.team_deleted",
          resource_uuid: resource_uuid,
          metadata_has: %{
            "db_pending" => true,
            "error_kind" => "atom",
            "error_atom" => "forbidden",
            "safe_extra" => "kept"
          }
        )

      # The helper-owned keys must reflect the actual state, not the
      # caller's bogus override.
      assert row.metadata["db_pending"] == true
      assert row.metadata["error_kind"] == "atom"
      assert row.metadata["error_atom"] == "forbidden"
    end
  end

  describe "resource_uuid is optional" do
    test "lands an audit row even with no resource_uuid (failed CREATE submissions)" do
      # Form Save failures on CREATE have no uuid yet — the helper
      # must accept `:resource_uuid` being absent and still record
      # the attempt so the audit feed captures what was tried.
      actor_uuid = Ecto.UUID.generate()

      Helpers.log_operation_error("staff.department_created", socket_with_actor(actor_uuid),
        reason: :forbidden,
        resource_type: "department",
        metadata: %{"attempted_name" => "New Eng"}
      )

      assert_activity_logged("staff.department_created",
        actor_uuid: actor_uuid,
        resource_uuid: nil,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "atom",
          "error_atom" => "forbidden",
          "attempted_name" => "New Eng"
        }
      )
    end
  end

  describe "actor_uuid threading" do
    test "actor_uuid is extracted from socket assigns and threaded through" do
      actor_uuid = Ecto.UUID.generate()
      resource_uuid = Ecto.UUID.generate()

      Helpers.log_operation_error("staff.team_deleted", socket_with_actor(actor_uuid),
        reason: :race,
        resource_type: "team",
        resource_uuid: resource_uuid
      )

      assert_activity_logged("staff.team_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: resource_uuid
      )
    end

    test "missing user assigns yields actor_uuid=nil but still logs" do
      resource_uuid = Ecto.UUID.generate()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}}
      }

      Helpers.log_operation_error("staff.person_deleted", socket,
        reason: :stale,
        resource_type: "staff_person",
        resource_uuid: resource_uuid
      )

      assert_activity_logged("staff.person_deleted",
        actor_uuid: nil,
        resource_uuid: resource_uuid,
        metadata_has: %{"db_pending" => true}
      )
    end
  end
end
