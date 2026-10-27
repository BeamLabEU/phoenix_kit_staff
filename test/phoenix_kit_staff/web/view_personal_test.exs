defmodule PhoenixKitStaff.Web.ViewPersonalTest do
  @moduledoc """
  `staff.view_personal` gates date of birth, personal email and phone,
  emergency contact and private notes: hidden from the people pages and
  the form without it, and a save without it neither writes nor wipes them.
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.Staff

  @personal %{
    "date_of_birth" => "1990-04-12",
    "personal_email" => "private@example.com",
    "personal_phone" => "+372 555 0101",
    "emergency_contact_name" => "Kin Person",
    "emergency_contact_phone" => "+372 555 0202",
    "emergency_contact_relationship" => "sibling",
    "notes" => "Private admin note"
  }

  defp base_scope do
    {:ok, _} = PhoenixKit.Settings.update_boolean_setting("staff_enabled", true)
    fake_scope(permissions: ["staff"])
  end

  defp assert_personal_intact(person) do
    reloaded = Staff.get_person(person.uuid)
    assert Date.to_string(reloaded.date_of_birth) == @personal["date_of_birth"]
    assert reloaded.personal_email == @personal["personal_email"]
    assert reloaded.personal_phone == @personal["personal_phone"]
    assert reloaded.emergency_contact_name == @personal["emergency_contact_name"]
    assert reloaded.emergency_contact_phone == @personal["emergency_contact_phone"]
    assert reloaded.emergency_contact_relationship == @personal["emergency_contact_relationship"]
    assert reloaded.notes == @personal["notes"]
    reloaded
  end

  describe "person show" do
    test "hides every personal detail from the base key", %{conn: conn} do
      person = fixture_person(Map.put(@personal, "name", "Shown Name"))

      {:ok, _view, html} =
        conn |> put_test_scope(base_scope()) |> live("/en/admin/staff/people/#{person.uuid}")

      assert html =~ "Shown Name"

      for value <- ["private@example.com", "+372 555 0101", "Kin Person", "+372 555 0202"] do
        refute html =~ value
      end

      refute html =~ "Private admin note"
      refute html =~ "Emergency contact"
      refute html =~ "Birthday"
    end

    test "shows them to a view_personal holder", %{conn: conn} do
      person = fixture_person(@personal)

      {:ok, _view, html} =
        conn |> put_test_scope(personal_scope()) |> live("/en/admin/staff/people/#{person.uuid}")

      assert html =~ "private@example.com"
      assert html =~ "Kin Person"
      assert html =~ "Private admin note"
      assert html =~ "Birthday"
    end
  end

  describe "overview" do
    setup do
      today = Date.utc_today()
      soon = Date.add(today, 3)
      dob = Date.new!(soon.year - 30, soon.month, soon.day)
      fixture_person(%{"date_of_birth" => Date.to_string(dob)})
      :ok
    end

    test "upcoming birthdays are hidden from the base key", %{conn: conn} do
      {:ok, _view, html} =
        conn |> put_test_scope(base_scope()) |> live("/en/admin/staff/overview")

      refute html =~ "Upcoming birthdays"
    end

    test "upcoming birthdays show to a view_personal holder", %{conn: conn} do
      {:ok, _view, html} =
        conn |> put_test_scope(personal_scope()) |> live("/en/admin/staff/overview")

      assert html =~ "Upcoming birthdays"
    end
  end

  describe "person form" do
    test "renders no personal inputs for the base key", %{conn: conn} do
      person = fixture_person(@personal)

      {:ok, _view, html} =
        conn
        |> put_test_scope(base_scope())
        |> live("/en/admin/staff/people/#{person.uuid}/edit")

      for field <- ~w(date_of_birth personal_email personal_phone emergency_contact_name
                      emergency_contact_phone emergency_contact_relationship) do
        refute html =~ ~s(name="person[#{field}]")
      end

      refute html =~ "private@example.com"
    end

    test "a base-key save keeps the personal details as they were", %{conn: conn} do
      person = fixture_person(@personal)

      {:ok, view, _html} =
        conn
        |> put_test_scope(base_scope())
        |> live("/en/admin/staff/people/#{person.uuid}/edit")

      view
      |> form("#person-form", person: %{name: "Renamed"})
      |> render_submit()

      reloaded = assert_personal_intact(person)
      assert reloaded.name == "Renamed"
    end

    test "a crafted base-key save can neither overwrite nor clear them", %{conn: conn} do
      person = fixture_person(@personal)

      {:ok, view, _html} =
        conn
        |> put_test_scope(base_scope())
        |> live("/en/admin/staff/people/#{person.uuid}/edit")

      render_submit(view, "save", %{
        "person" => %{
          "status" => "active",
          "date_of_birth" => "",
          "personal_email" => "attacker@example.com",
          "personal_phone" => "",
          "emergency_contact_name" => "",
          "emergency_contact_phone" => "",
          "emergency_contact_relationship" => "",
          "notes" => "overwritten",
          "translations" => %{"et-EE" => %{"notes" => "üle kirjutatud"}}
        },
        "email" => ""
      })

      reloaded = assert_personal_intact(person)
      refute get_in(reloaded.translations, ["et-EE", "notes"])
    end

    test "a crafted base-key create cannot set them", %{conn: conn} do
      email = "new-#{System.unique_integer([:positive])}@example.com"

      {:ok, view, _html} =
        conn |> put_test_scope(base_scope()) |> live("/en/admin/staff/people/new")

      render_submit(view, "save", %{
        "person" => Map.put(@personal, "status", "active"),
        "email" => email
      })

      [created] = Staff.list_people(search: email)
      assert created.date_of_birth == nil
      assert created.personal_email == nil
      assert created.emergency_contact_name == nil
      assert created.notes == nil
    end

    test "a view_personal holder edits them", %{conn: conn} do
      person = fixture_person(@personal)

      {:ok, view, _html} =
        conn
        |> put_test_scope(personal_scope())
        |> live("/en/admin/staff/people/#{person.uuid}/edit")

      view
      |> form("#person-form", person: %{personal_email: "changed@example.com"})
      |> render_submit()

      assert Staff.get_person(person.uuid).personal_email == "changed@example.com"
    end
  end

  describe "grant revoked mid-session" do
    # A "validate" sent while the viewer held the key stages personal values
    # in the form's changeset; the merge would otherwise preserve them into a
    # save made after the grant is gone.
    test "staged personal values never reach the database", %{conn: conn} do
      person = fixture_person(@personal)

      {:ok, view, _html} =
        conn
        |> put_test_scope(personal_scope())
        |> live("/en/admin/staff/people/#{person.uuid}/edit")

      render_change(view, "validate", %{
        "person" => %{
          "notes" => "staged while held",
          "personal_email" => "staged@example.com",
          "translations" => %{"et-EE" => %{"notes" => "lavastatud"}}
        },
        "email" => ""
      })

      swap_scope(view, fake_scope(permissions: ["staff"]))

      render_submit(view, "save", %{
        "person" => %{"status" => "active", "name" => "Renamed after revoke"},
        "email" => ""
      })

      reloaded = assert_personal_intact(person)
      assert reloaded.name == "Renamed after revoke"
      refute get_in(reloaded.translations, ["et-EE", "notes"])
    end
  end
end
