defmodule PhoenixKitStaff.Integration.AttachmentsAvatarTest do
  @moduledoc "Avatar pointer round-trips through Person.metadata (no Storage tables needed)."
  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.Attachments

  defp repo, do: PhoenixKit.RepoHelper.repo()

  test "set/clear avatar round-trips and avatar_uuid reads it back" do
    person = fixture_person()
    assert Attachments.avatar_uuid(person) == nil

    uuid = Ecto.UUID.generate()
    {:ok, updated} = Attachments.set_avatar(person, uuid)
    assert Attachments.avatar_uuid(updated) == uuid

    {:ok, cleared} = Attachments.clear_avatar(updated)
    assert Attachments.avatar_uuid(cleared) == nil
  end

  test "setting the avatar preserves other metadata keys" do
    person = fixture_person()

    {:ok, person} =
      person
      |> Ecto.Changeset.change(metadata: %{"trashed_from_status" => "active"})
      |> repo().update()

    uuid = Ecto.UUID.generate()
    {:ok, updated} = Attachments.set_avatar(person, uuid)

    assert updated.metadata["avatar_uuid"] == uuid
    assert updated.metadata["trashed_from_status"] == "active"
  end

  test "avatar_file is nil when the pointer references a missing/absent file" do
    # No Storage tables in the test harness, so get_file fails and is rescued.
    person = fixture_person()
    {:ok, updated} = Attachments.set_avatar(person, Ecto.UUID.generate())
    assert Attachments.avatar_file(updated) == nil
    assert Attachments.avatar_url(updated) == nil
  end
end
