defmodule PhoenixKitStaff.Integration.AttachmentsParentFolderTest do
  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitStaff.Attachments

  # Delegates to a per-test function so each test can shape the hook's answer.
  defmodule Hook do
    def parent(kind, actor, subject), do: Process.get(:hook).(kind, actor, subject)
  end

  defmodule TwoArityHook do
    def parent(:person, _actor), do: {:ok, Process.get(:staff)}
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_staff, :attachments_parent_folder) end)
    staff = folder!("Staff")
    Process.put(:staff, staff.uuid)
    %{staff: staff}
  end

  defp folder!(name, parent_uuid \\ nil) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: "#{name}-#{System.unique_integer([:positive])}",
        parent_uuid: parent_uuid
      })

    folder
  end

  defp hook(fun) do
    Process.put(:hook, fun)
    Application.put_env(:phoenix_kit_staff, :attachments_parent_folder, {Hook, :parent})
  end

  defp hook_on, do: hook(fn :person, _actor, _subject -> {:ok, Process.get(:staff)} end)

  defp count_named(uuid),
    do: Repo.aggregate(from(f in Folder, where: f.name == ^"staff-person-#{uuid}"), :count)

  test "without config the folder is created at root" do
    uuid = Ecto.UUID.generate()
    assert {:ok, fuuid} = Attachments.ensure_folder(uuid, :files, nil)
    assert Repo.get!(Folder, fuuid).parent_uuid == nil
  end

  test "with config root under the parent, Images under root", %{staff: s} do
    hook_on()
    uuid = Ecto.UUID.generate()
    assert {:ok, root} = Attachments.ensure_folder(uuid, :files, nil)
    assert Repo.get!(Folder, root).parent_uuid == s.uuid
    assert {:ok, images} = Attachments.ensure_folder(uuid, :images, nil)
    assert Repo.get!(Folder, images).parent_uuid == root
    assert Attachments.folder_uuid(uuid, :files) == root
    assert Attachments.folder_uuid(uuid, :images) == images
  end

  test "the hook receives the person uuid as its subject" do
    test_pid = self()

    hook(fn :person, actor, subject ->
      send(test_pid, {:hook_called, actor, subject})
      nil
    end)

    uuid = Ecto.UUID.generate()
    actor = fixture_person().user_uuid
    assert {:ok, _} = Attachments.ensure_folder(uuid, :files, actor)
    assert_received {:hook_called, ^actor, ^uuid}
  end

  test "a two-arity hook is honoured", %{staff: s} do
    Application.put_env(:phoenix_kit_staff, :attachments_parent_folder, {TwoArityHook, :parent})
    uuid = Ecto.UUID.generate()
    assert {:ok, root} = Attachments.ensure_folder(uuid, :files, nil)
    assert Repo.get!(Folder, root).parent_uuid == s.uuid
  end

  test "a hook that raises or exits falls back to root" do
    uuid = Ecto.UUID.generate()

    hook(fn _, _, _ -> raise "boom" end)
    assert {:ok, root} = Attachments.ensure_folder(uuid, :files, nil)
    assert Repo.get!(Folder, root).parent_uuid == nil

    hook(fn _, _, _ -> exit(:down) end)
    assert Attachments.parent_folder_uuid(:person, nil, uuid) == nil
  end

  test "a folder created at root before the hook is still found and not twinned" do
    uuid = Ecto.UUID.generate()
    {:ok, legacy} = Attachments.ensure_folder(uuid, :files, nil)
    hook_on()
    assert Attachments.folder_uuid(uuid, :files) == legacy
    assert {:ok, ^legacy} = Attachments.ensure_folder(uuid, :files, nil)
    assert count_named(uuid) == 1
  end

  test "an actor-dependent hook: render without the actor and a second actor both find the folder" do
    parent_a = folder!("A")
    parent_b = folder!("B")
    actor_a = fixture_person().user_uuid
    actor_b = fixture_person().user_uuid

    hook(fn :person, actor, _subject ->
      cond do
        actor == actor_a -> {:ok, parent_a.uuid}
        actor == actor_b -> {:ok, parent_b.uuid}
        true -> nil
      end
    end)

    uuid = Ecto.UUID.generate()
    {:ok, images} = Attachments.ensure_folder(uuid, :images, actor_a)
    {:ok, root} = Attachments.ensure_folder(uuid, :files, actor_a)
    assert Repo.get!(Folder, root).parent_uuid == parent_a.uuid

    assert Attachments.folder_uuid(uuid, :files) == root
    assert Attachments.folder_uuid(uuid, :images) == images
    assert {:ok, ^root} = Attachments.ensure_folder(uuid, :files, actor_b)
    assert count_named(uuid) == 1
  end

  test "purge_person_media deletes a nested folder" do
    hook_on()
    uuid = Ecto.UUID.generate()
    {:ok, root} = Attachments.ensure_folder(uuid, :images, nil)
    assert :ok = Attachments.purge_person_media(uuid)
    assert Repo.get(Folder, root) == nil
  end

  test "purge_person_media removes the person's folder wherever it sits, twins included" do
    uuid = Ecto.UUID.generate()
    name = Attachments.root_folder_name(uuid)
    other = folder!("Other")

    {:ok, at_root} = Storage.create_folder(%{name: name})
    {:ok, nested} = Storage.create_folder(%{name: name, parent_uuid: other.uuid})

    # The hook now points somewhere else entirely.
    hook_on()
    assert :ok = Attachments.purge_person_media(uuid)
    assert Repo.get(Folder, at_root.uuid) == nil
    assert Repo.get(Folder, nested.uuid) == nil
    assert Repo.get(Folder, other.uuid)
  end
end
