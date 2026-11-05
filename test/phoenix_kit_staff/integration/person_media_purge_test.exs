defmodule PhoenixKitStaff.Integration.PersonMediaPurgeTest do
  @moduledoc """
  A permanent delete purges the person's media folder whichever path it came
  through, and only for rows actually deleted.
  """
  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitStaff.{Attachments, Staff}

  defp person_with_folder do
    person = fixture_person()
    {:ok, _folder} = Storage.create_folder(%{name: Attachments.root_folder_name(person.uuid)})
    person
  end

  defp folder?(person) do
    Repo.get_by(Folder, name: Attachments.root_folder_name(person.uuid)) != nil
  end

  defp trashed(person) do
    {:ok, person} = Staff.trash_person(person)
    person
  end

  test "delete_person/1 purges the media folder" do
    person = person_with_folder() |> trashed()

    assert {:ok, _} = Staff.delete_person(person)

    refute folder?(person)
  end

  test "a refused delete_person/1 keeps the media folder" do
    person = person_with_folder()

    assert {:error, :not_trashed} = Staff.delete_person(person)

    assert folder?(person)
  end

  test "bulk_delete/1 purges the deleted rows and keeps a live person's folder" do
    gone = person_with_folder() |> trashed()
    live = person_with_folder()

    assert {:ok, 1} = Staff.bulk_delete([gone.uuid, live.uuid])

    refute folder?(gone)
    assert folder?(live)
  end
end
