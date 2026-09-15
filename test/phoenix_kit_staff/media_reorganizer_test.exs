defmodule PhoenixKitStaff.MediaReorganizerTest do
  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitStaff.MediaReorganizer
  alias PhoenixKitStaff.Schemas.Person
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

  defmodule RaisingHook do
    def parent(:person, _actor, _subject), do: raise("boom")
    def parent(_, _, _), do: nil
  end

  defmodule ErrorHook do
    def parent(:person, _actor, _subject), do: {:error, :timeout}
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

    test "legacy folder live in two places, neither root nor the resolved parent → one duplicate report, not silently dropped" do
      person = fixture_person(%{"name" => "Scattered"})
      {:ok, target} = Storage.create_folder(%{name: "Staff"})
      {:ok, elsewhere1} = Storage.create_folder(%{name: "Somewhere else 1"})
      {:ok, elsewhere2} = Storage.create_folder(%{name: "Somewhere else 2"})

      {:ok, folder1} =
        Storage.create_folder(%{
          name: "staff-person-#{person.uuid}",
          parent_uuid: elsewhere1.uuid
        })

      {:ok, folder2} =
        Storage.create_folder(%{
          name: "staff-person-#{person.uuid}",
          parent_uuid: elsewhere2.uuid
        })

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :person and &1.label == "Scattered"))
      refute Enum.any?(actions, &(&1.kind == :relocated and &1.label == "Scattered"))

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == "Scattered"))
      refute is_nil(dup)
      assert dup.op == :report
      assert dup.reason =~ folder1.uuid
      assert dup.reason =~ folder2.uuid
    end
  end

  describe "legacy folder relocated elsewhere" do
    test "legacy folder live under a parent that isn't root or the resolved parent → reported :relocated, not adopted" do
      person = fixture_person(%{"name" => "Relocated"})
      {:ok, target} = Storage.create_folder(%{name: "Staff"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})

      {:ok, folder} =
        Storage.create_folder(%{name: "staff-person-#{person.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :person and &1.op == :move))
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == "Relocated"))
      refute is_nil(relocated)
      assert relocated.op == :report
      assert relocated.folder.uuid == folder.uuid
      # E6: staff's hook is actor-dependent — the report says so instead of
      # implying the folder is unconditionally misplaced.
      assert relocated.reason =~ "acting user"
    end
  end

  describe "hook failure (R2)" do
    test "hook raises → record skipped, one hook_error report with the count, never planned as root" do
      person = fixture_person()
      {:ok, _folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

      Application.put_env(:phoenix_kit_staff, :attachments_parent_folder, {RaisingHook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :person))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.op == :report
      assert error.reason =~ "1 record"
    end

    test "hook returns {:error, _} → same as raising, never treated as root" do
      person = fixture_person()
      {:ok, _folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

      Application.put_env(:phoenix_kit_staff, :attachments_parent_folder, {ErrorHook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :person and &1.op == :move))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
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

  describe "hook call discipline (X12/R8)" do
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

      # No candidate at all → no hook call whatsoever: not for the person
      # (no folder to move), and not a subject-less per-plan call either
      # (R8 — that call was removed; see the orphan tests below for the
      # resulting trade-off).
      assert calls == []
    end

    test "one candidate → the hook is called exactly once, for that person" do
      person = fixture_person()
      {:ok, target} = Storage.create_folder(%{name: "Staff"})
      {:ok, _folder} = Storage.create_folder(%{name: "staff-person-#{person.uuid}"})

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

      assert calls == [person.uuid]
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

    test "orphan folder found under a parent resolved via a live candidate, not only at root" do
      uuid = Ecto.UUID.generate()
      {:ok, target} = Storage.create_folder(%{name: "Staff"})

      {:ok, folder} =
        Storage.create_folder(%{name: "staff-person-#{uuid}", parent_uuid: target.uuid})

      # A live person whose own folder already sits at `target` anchors the
      # resolved-parent set — the orphan under the very same parent is then
      # found too.
      candidate = fixture_person()

      {:ok, _candidate_folder} =
        Storage.create_folder(%{name: "staff-person-#{candidate.uuid}", parent_uuid: target.uuid})

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
    end

    test "orphan under a parent no live candidate resolved to is not found (R8 — no subject-less hook call)" do
      uuid = Ecto.UUID.generate()
      {:ok, target} = Storage.create_folder(%{name: "Staff"})

      {:ok, folder} =
        Storage.create_folder(%{name: "staff-person-#{uuid}", parent_uuid: target.uuid})

      # No live person fixture at all — with no candidate to resolve a
      # parent from, the hook is never called (R8), `target` never becomes
      # a resolved parent, and only root is checked for orphans.
      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
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

  describe "deterministic order (R10)" do
    test "person move actions ordered by inserted_at then uuid, not DB read order" do
      person_a = fixture_person(%{"name" => "Alpha"})
      person_b = fixture_person(%{"name" => "Beta"})

      {:ok, target} = Storage.create_folder(%{name: "Staff"})
      {:ok, _folder_a} = Storage.create_folder(%{name: "staff-person-#{person_a.uuid}"})
      {:ok, _folder_b} = Storage.create_folder(%{name: "staff-person-#{person_b.uuid}"})

      # person_b was inserted after person_a, but back-date it so a plan
      # that merely read rows in table order would get the pair backwards
      # — only an explicit ORDER BY inserted_at, uuid is correct here.
      earlier =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(p in Person, where: p.uuid == ^person_b.uuid),
        set: [inserted_at: earlier]
      )

      Process.put(:target_folder, target.uuid)
      hook_on()

      actions = MediaReorganizer.plan(nil, [])
      labels = actions |> Enum.filter(&(&1.kind == :person)) |> Enum.map(& &1.label)

      assert labels == ["Beta", "Alpha"]
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
