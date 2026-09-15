defmodule PhoenixKitStaff.MediaReorganizerTest do
  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitStaff.MediaReorganizer
  alias PhoenixKitStaff.Staff

  defmodule Hook do
    def parent(:person, _actor, _subject), do: {:ok, Process.get(:target_folder)}
    def parent(_, _, _), do: nil
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_staff, :attachments_parent_folder) end)
    :ok
  end

  defp hook_on,
    do: Application.put_env(:phoenix_kit_staff, :attachments_parent_folder, {Hook, :parent})

  test "no hook configured, legacy folder at root → nothing planned" do
    person = fixture_person()
    {:ok, _folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :person and &1.label == person.name))
  end

  test "no hook, no folder at all → nothing planned" do
    _person = fixture_person()

    actions = MediaReorganizer.plan(nil, [])
    assert actions == []
  end

  test "hook configured, legacy folder at root → one move action, no after_move" do
    person = fixture_person(%{"name" => "Marta Kask"})
    {:ok, target} = Storage.create_folder(%{name: "Staff"})
    {:ok, folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :person and &1.label == "Marta Kask"))

    refute is_nil(action)
    assert action.source == "staff"
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == "staff-person-#{person.uuid}"
    assert action.on_conflict == :suffix
    assert action.counts == {0, 0}
    assert is_nil(action.after_move)
  end

  test "folder already under the resolved parent with the right name → nothing planned (noop)" do
    person = fixture_person()
    {:ok, target} = Storage.create_folder(%{name: "Staff"})

    {:ok, _folder} =
      Storage.create_folder(%{name: "staff-person-#{person.uuid}", parent_uuid: target.uuid})

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :person and &1.label == person.name))
  end

  test "folder in place under an accepted suffixed name variant → nothing planned" do
    person = fixture_person()
    {:ok, target} = Storage.create_folder(%{name: "Staff"})

    {:ok, _folder} =
      Storage.create_folder(%{
        name: "staff-person-#{person.uuid} (2)",
        parent_uuid: target.uuid
      })

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :person and &1.label == person.name))
  end

  test "counts include a trashed file — engine re-measures the same way at apply time" do
    person = fixture_person(%{"name" => "Käepide"})
    {:ok, target} = Storage.create_folder(%{name: "Staff"})
    {:ok, folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

    {:ok, _trashed_file} =
      Storage.create_file(%{
        original_file_name: "old.pdf",
        file_name: "old.pdf",
        mime_type: "application/pdf",
        file_type: "document",
        ext: "pdf",
        file_checksum: "checksum-trashed-#{person.uuid}",
        user_file_checksum: "user-checksum-trashed-#{person.uuid}",
        size: 10,
        status: "trashed",
        folder_uuid: folder.uuid,
        user_uuid: person.user_uuid
      })

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :person and &1.label == person.name))

    assert action.counts == {1, 0}
  end

  test "trashed folder at root, no live folder anywhere → nothing planned (skipped)" do
    person = fixture_person()
    {:ok, folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})
    {:ok, _folder} = Storage.trash_folder(folder)

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :person and &1.label == person.name))
  end

  test "pointer points nowhere (staff has none) — trashed root + live folder under parent → live one used" do
    person = fixture_person()
    {:ok, target} = Storage.create_folder(%{name: "Staff"})
    {:ok, trashed_root} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})
    {:ok, _trashed_root} = Storage.trash_folder(trashed_root)

    {:ok, live_folder} =
      Storage.create_folder(%{name: "staff-person-#{person.uuid}", parent_uuid: target.uuid})

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :person and &1.label == person.name))
    # The live folder is already in place under the resolved parent, so
    # nothing moves — confirms the trashed root copy was correctly skipped
    # rather than surfaced as the current folder.
    assert Storage.get_folder(live_folder.uuid)
  end

  describe "trashed people" do
    test "trashed person with a live folder → not planned" do
      person = fixture_person()
      {:ok, _folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})
      {:ok, _trashed} = Staff.trash_person(person)

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :person))
    end
  end

  describe "orphan folders" do
    test "legacy folder with no matching person record → orphan report with counts" do
      uuid = Ecto.UUID.generate()
      {:ok, folder} = Storage.create_folder(%{name: "staff-person-#{uuid}"})

      person = fixture_person()

      {:ok, _file} =
        Storage.create_file(%{
          original_file_name: "stray.pdf",
          file_name: "stray.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-orphan-#{uuid}",
          user_file_checksum: "user-checksum-orphan-#{uuid}",
          size: 5,
          status: "active",
          folder_uuid: folder.uuid,
          user_uuid: person.user_uuid
        })

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.source == "staff"
      assert action.op == :report
      assert action.counts == {1, 0}
      assert action.reason =~ "missing"
      assert action.reason =~ "1 file"
    end

    test "legacy folder of a trashed person → report names the record's status" do
      person = fixture_person()
      {:ok, folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})
      {:ok, _trashed} = Staff.trash_person(person)

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.op == :report
      assert action.reason =~ "trashed"
    end

    test "legacy folder of a live person → not reported as orphan" do
      person = fixture_person()
      {:ok, folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "orphan folder found under a resolved parent too, not only at root" do
      uuid = Ecto.UUID.generate()
      {:ok, target} = Storage.create_folder(%{name: "Staff"})

      {:ok, folder} =
        Storage.create_folder(%{name: "staff-person-#{uuid}", parent_uuid: target.uuid})

      # Give the batch a resolved parent to search under by having one live
      # person whose hook resolves to the same target folder.
      _person = fixture_person()
      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
    end

    test "trashed folder is skipped, never reported as orphan" do
      uuid = Ecto.UUID.generate()
      {:ok, folder} = Storage.create_folder(%{name: "staff-person-#{uuid}"})
      {:ok, _folder} = Storage.trash_folder(folder)

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end
end
