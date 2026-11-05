defmodule PhoenixKitStaff.Integration.PersonSaveEdgesTest do
  @moduledoc "Context-level edges of saving a person and renaming a placeholder."
  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKitStaff.Staff
  alias PhoenixKitStaff.Staff.Org

  test "a department that does not exist is a changeset error, not a raise" do
    person = fixture_person()

    assert {:error, changeset} =
             Staff.update_person(person, %{"primary_department_uuid" => UUIDv7.generate()})

    assert %{primary_department_uuid: [_ | _]} = errors_on(changeset)
  end

  describe "rename_placeholder_email/2" do
    # Core confirms the first user of a database as its Owner, so a placeholder
    # needs someone registered before it.
    setup do
      fixture_person()
      %{person: fixture_person()}
    end

    test "refuses an account claimed since the caller read it", %{person: person} do
      stale = person.user

      Repo.update!(Ecto.Changeset.change(stale, confirmed_at: DateTime.utc_now(:second)))

      assert {:error, :placeholder_already_claimed} =
               Staff.rename_placeholder_email(stale, "renamed@example.com")

      assert Repo.reload!(stale).email == stale.email
    end

    test "an email the account already has is no change, whatever the caller read", %{
      person: person
    } do
      stale = person.user

      assert {:ok, _user} = Staff.rename_placeholder_email(stale, "renamed@example.com")

      assert :ok = Staff.rename_placeholder_email(stale, "renamed@example.com")
    end
  end

  describe "next_birthday_and_days/2" do
    test "counts to the real day across the new year" do
      assert Org.next_birthday_and_days(~D[1990-01-31], ~D[2026-12-31]) == {~D[2027-01-31], 31}
    end

    test "falls back to Feb 28 only in a non-leap year" do
      assert {~D[2027-02-28], _} = Org.next_birthday_and_days(~D[2000-02-29], ~D[2026-12-31])
      assert {~D[2028-02-29], _} = Org.next_birthday_and_days(~D[2000-02-29], ~D[2027-12-31])
    end
  end
end
