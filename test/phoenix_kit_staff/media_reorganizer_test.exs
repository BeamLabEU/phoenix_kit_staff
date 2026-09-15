defmodule PhoenixKitStaff.MediaReorganizerTest do
  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitStaff.MediaReorganizer
  alias PhoenixKitStaff.Staff

  defmodule Hook do
    def parent(:person, _actor, _subject), do: {:ok, Process.get(:target_folder)}
    def parent(_, _, _), do: nil
  end

  defmodule TwoArityHook do
    def parent(:person, _actor), do: {:ok, Process.get(:target_folder)}
    def parent(_, _), do: nil
  end

  defmodule CallCountingHook do
    def parent(:person, _actor, subject) do
      Agent.update(__MODULE__.Counter, &[subject | &1])
      {:ok, Process.get(:target_folder)}
    end

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

  test "hook configured, legacy folder at root → one move action, on_conflict :report, no after_move" do
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
    assert action.on_conflict == :report
    assert action.counts == {0, 0}
    assert is_nil(action.after_move)
  end

  test "2-arity hook (no subject argument) is honored" do
    person = fixture_person()
    {:ok, target} = Storage.create_folder(%{name: "Staff"})
    {:ok, folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_staff, :attachments_parent_folder, {TwoArityHook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :person and &1.folder.uuid == folder.uuid))

    refute is_nil(action)
    assert action.parent_uuid == target.uuid
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

  test "trashed folder sharing the legacy name under the resolved parent does not shadow the live root folder (X2)" do
    person = fixture_person()
    {:ok, target} = Storage.create_folder(%{name: "Staff"})

    {:ok, trashed_under_parent} =
      Storage.create_folder(%{name: "staff-person-#{person.uuid}", parent_uuid: target.uuid})

    {:ok, _trashed_under_parent} = Storage.trash_folder(trashed_under_parent)

    {:ok, live_folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

    Process.put(:target_folder, target.uuid)
    hook_on()

    actions = MediaReorganizer.plan(nil, [])

    # Without the trashed_at SQL filter, the trashed folder under the
    # resolved parent would be picked up as a second live-looking match
    # alongside the real live folder at root, misreporting this as a
    # duplicate instead of moving the one true live folder.
    refute Enum.any?(actions, &(&1.kind == :duplicate))
    action = Enum.find(actions, &(&1.kind == :person and &1.folder.uuid == live_folder.uuid))
    refute is_nil(action)
    assert action.op == :move
    assert action.parent_uuid == target.uuid
  end

  test "no hooks configured, legacy folder live in two places → not a duplicate report (no resolved parent at all)" do
    person = fixture_person()
    {:ok, other} = Storage.create_folder(%{name: "Somewhere else"})

    {:ok, _at_root} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

    {:ok, _elsewhere} =
      Storage.create_folder(%{name: "staff-person-#{person.uuid}", parent_uuid: other.uuid})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind in [:person, :duplicate] and &1.label == person.name))
  end

  describe "duplicate folders (X8/X11)" do
    test "legacy folder live at both root and under the resolved parent → one duplicate report, no move" do
      person = fixture_person(%{"name" => "Duplicated"})
      {:ok, target} = Storage.create_folder(%{name: "Staff"})
      {:ok, at_root} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

      {:ok, under_parent} =
        Storage.create_folder(%{name: "staff-person-#{person.uuid}", parent_uuid: target.uuid})

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :person and &1.label == "Duplicated"))

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == "Duplicated"))
      refute is_nil(dup)
      assert dup.op == :report
      assert dup.reason =~ at_root.uuid
      assert dup.reason =~ under_parent.uuid
    end
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

  describe "hook call discipline (X12)" do
    test "a person with no candidate folder never triggers the parent hook" do
      _person = fixture_person()
      {:ok, target} = Storage.create_folder(%{name: "Staff"})

      Process.put(:target_folder, target.uuid)
      {:ok, _} = Agent.start_link(fn -> [] end, name: CallCountingHook.Counter)

      Application.put_env(
        :phoenix_kit_staff,
        :attachments_parent_folder,
        {CallCountingHook, :parent}
      )

      MediaReorganizer.plan(nil, [])

      calls = Agent.get(CallCountingHook.Counter, & &1)
      Agent.stop(CallCountingHook.Counter)

      # Only the single subject-less (X13) call, never one for the person
      # who has no folder at all.
      assert calls == [nil]
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

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
    end

    test "orphan under the resolved parent is found even with zero live people (X13)" do
      uuid = Ecto.UUID.generate()
      {:ok, target} = Storage.create_folder(%{name: "Staff"})

      {:ok, folder} =
        Storage.create_folder(%{name: "staff-person-#{uuid}", parent_uuid: target.uuid})

      # No live person fixture at all — the resolved parent can only come
      # from the subject-less kind-level hook call, not from any
      # candidate's `parent_uuid`.
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

    test "a folder whose name merely starts with a person uuid-looking suffix but isn't a strict UUID is ignored" do
      {:ok, _folder} = Storage.create_folder(%{name: "staff-person-not-a-uuid"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.label == "staff-person-not-a-uuid"))
    end
  end

  describe "label fallback" do
    test "blank person name falls back to the person uuid" do
      person = fixture_person(%{"name" => ""})
      {:ok, target} = Storage.create_folder(%{name: "Staff"})
      {:ok, _folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :person and &1.label == person.uuid))

      refute is_nil(action)
    end
  end
end
