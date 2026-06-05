defmodule PhoenixKitStaff.Integration.SoftDeleteTest do
  @moduledoc """
  Soft-delete (trash / restore / permanent delete) for staff people:
  status-sentinel behavior, prior-status preservation via the V130
  `metadata` column, default-scope exclusion, the bulk set-based
  variants, and the `trashed_person_exists` re-onboarding guard.
  """

  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKitStaff.Staff
  alias PhoenixKitStaff.Schemas.Person

  describe "trash_person/1" do
    test "sets status to trashed and stashes the prior status" do
      person = fixture_person(%{"status" => "inactive"})

      assert {:ok, trashed} = Staff.trash_person(person)
      assert trashed.status == "trashed"
      assert trashed.metadata["trashed_from_status"] == "inactive"
      assert Person.trashed?(trashed)
    end

    test "is idempotent-safe: already-trashed returns an error" do
      person = fixture_person()
      {:ok, trashed} = Staff.trash_person(person)
      assert {:error, :already_trashed} = Staff.trash_person(trashed)
    end
  end

  describe "restore_person/1" do
    test "returns to the stashed prior status and clears the stash" do
      person = fixture_person(%{"status" => "inactive"})
      {:ok, trashed} = Staff.trash_person(person)

      assert {:ok, restored} = Staff.restore_person(trashed)
      assert restored.status == "inactive"
      refute Map.has_key?(restored.metadata, "trashed_from_status")
    end

    test "defaults to active when the stash is missing or garbage" do
      person = fixture_person(%{"status" => "active"})
      # Simulate a row trashed with a junk stash value.
      {:ok, trashed} = Staff.trash_person(person)

      {:ok, junk} =
        Staff.update_person(trashed, %{"metadata" => %{"trashed_from_status" => "bogus"}})

      assert {:ok, restored} = Staff.restore_person(junk)
      assert restored.status == "active"
    end

    test "non-trashed person returns an error" do
      person = fixture_person()
      assert {:error, :not_trashed} = Staff.restore_person(person)
    end
  end

  describe "delete_person/1 (permanent)" do
    test "hard-deletes the row" do
      person = fixture_person()
      assert {:ok, _} = Staff.delete_person(person)
      assert Staff.get_person(person.uuid) == nil
    end
  end

  describe "list_people/1 scoping" do
    test "excludes trashed by default; status: \"trashed\" returns only trashed" do
      active = fixture_person(%{"status" => "active"})
      to_trash = fixture_person()
      {:ok, trashed} = Staff.trash_person(to_trash)

      default_uuids = Staff.list_people() |> Enum.map(& &1.uuid)
      assert active.uuid in default_uuids
      refute trashed.uuid in default_uuids

      trash_uuids = Staff.list_people(status: "trashed") |> Enum.map(& &1.uuid)
      assert trash_uuids == [trashed.uuid]

      all_uuids = Staff.list_people(include_trashed: true) |> Enum.map(& &1.uuid)
      assert active.uuid in all_uuids
      assert trashed.uuid in all_uuids
    end
  end

  describe "count_people/0 and count_trashed/0" do
    test "count_people excludes trashed; count_trashed counts only trashed" do
      _a = fixture_person()
      b = fixture_person()
      {:ok, _} = Staff.trash_person(b)

      assert Staff.count_people() == 1
      assert Staff.count_trashed() == 1
    end
  end

  describe "create_person/1 trashed-profile guard" do
    test "returns trashed_person_exists when the user already has a trashed profile" do
      person = fixture_person()
      {:ok, _trashed} = Staff.trash_person(person)

      assert {:error, {:trashed_person_exists, existing}} =
               Staff.create_person(%{"user_uuid" => person.user_uuid, "status" => "active"})

      assert existing.uuid == person.uuid
    end
  end

  describe "bulk operations" do
    test "bulk_trash stashes per-row prior status and skips already-trashed" do
      a = fixture_person(%{"status" => "active"})
      b = fixture_person(%{"status" => "inactive"})
      {:ok, already} = Staff.trash_person(fixture_person())

      assert {:ok, 2} = Staff.bulk_trash([a.uuid, b.uuid, already.uuid])

      assert Staff.get_person(a.uuid).metadata["trashed_from_status"] == "active"
      assert Staff.get_person(b.uuid).metadata["trashed_from_status"] == "inactive"
      assert Staff.count_trashed() == 3
    end

    test "bulk_restore returns each row to its stashed status" do
      a = fixture_person(%{"status" => "active"})
      b = fixture_person(%{"status" => "inactive"})
      {:ok, 2} = Staff.bulk_trash([a.uuid, b.uuid])

      assert {:ok, 2} = Staff.bulk_restore([a.uuid, b.uuid])
      assert Staff.get_person(a.uuid).status == "active"
      assert Staff.get_person(b.uuid).status == "inactive"
      assert Staff.count_trashed() == 0
    end

    test "bulk_delete permanently removes rows" do
      a = fixture_person()
      b = fixture_person()
      assert {:ok, 2} = Staff.bulk_delete([a.uuid, b.uuid])
      assert Staff.get_person(a.uuid) == nil
      assert Staff.get_person(b.uuid) == nil
    end
  end

  describe "org_tree/0 and people_not_on_team/1 exclude trashed" do
    test "a trashed member drops out of the team roster and the add-picker" do
      team = fixture_team()
      person = fixture_person()
      {:ok, _} = Staff.add_team_person(team.uuid, person.uuid)

      # On the team before trashing; not in the add-picker.
      refute person.uuid in (Staff.people_not_on_team(team.uuid) |> Enum.map(& &1.uuid))

      {:ok, _} = Staff.trash_person(person)

      roster_uuids =
        Staff.org_tree().departments
        |> Enum.flat_map(fn d ->
          Enum.flat_map(d.teams, fn t -> Enum.map(t.people, & &1.uuid) end)
        end)

      refute person.uuid in roster_uuids
      # Still excluded from the picker (trashed, not "available").
      refute person.uuid in (Staff.people_not_on_team(team.uuid) |> Enum.map(& &1.uuid))
    end
  end
end
