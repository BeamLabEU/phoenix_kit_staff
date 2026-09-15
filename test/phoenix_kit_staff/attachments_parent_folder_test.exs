defmodule PhoenixKitStaff.AttachmentsParentFolderTest do
  use PhoenixKitStaff.DataCase, async: false

  import Ecto.Query
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitStaff.Attachments

  defmodule Hook do
    def parent(:person, _actor, _subject), do: {:ok, Process.get(:staff)}
    def parent(_, _, _), do: nil
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_staff, :attachments_parent_folder) end)
    {:ok, staff} = Storage.create_folder(%{name: "Staff-#{System.unique_integer([:positive])}"})
    Process.put(:staff, staff.uuid)
    %{staff: staff}
  end

  defp hook_on,
    do: Application.put_env(:phoenix_kit_staff, :attachments_parent_folder, {Hook, :parent})

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

  test "a folder created at root before the hook is still found and not twinned" do
    uuid = Ecto.UUID.generate()
    {:ok, legacy} = Attachments.ensure_folder(uuid, :files, nil)
    hook_on()
    assert Attachments.folder_uuid(uuid, :files) == legacy
    assert {:ok, ^legacy} = Attachments.ensure_folder(uuid, :files, nil)

    assert Repo.aggregate(from(f in Folder, where: f.name == ^"staff-person-#{uuid}"), :count) ==
             1
  end

  test "purge_person_media deletes a nested folder" do
    hook_on()
    uuid = Ecto.UUID.generate()
    {:ok, root} = Attachments.ensure_folder(uuid, :images, nil)
    assert :ok = Attachments.purge_person_media(uuid)
    assert Repo.get(Folder, root) == nil
  end
end
