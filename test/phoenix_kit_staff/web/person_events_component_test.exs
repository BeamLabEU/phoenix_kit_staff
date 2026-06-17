defmodule PhoenixKitStaff.Web.PersonEventsComponentTest do
  @moduledoc "Smoke tests for the read-only Events tab on the person profile."

  use PhoenixKitStaff.LiveCase, async: false

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp open_events(conn, person) do
    {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")
    render_click(view, "switch_tab", %{"tab" => "events"})
  end

  test "renders the person's logged activity with a humanized label", %{conn: conn} do
    person = fixture_person()

    {:ok, _} =
      PhoenixKit.Activity.log(%{
        action: "staff.person_updated",
        module: "staff",
        resource_type: "staff_person",
        resource_uuid: person.uuid,
        metadata: %{}
      })

    html = open_events(conn, person)

    assert html =~ "Events"
    assert html =~ "Profile updated"
  end

  test "shows an empty state when the person has no activity", %{conn: conn} do
    person = fixture_person()
    html = open_events(conn, person)

    assert html =~ "No activity recorded for this person yet."
  end

  test "scopes to this person — another person's activity does not leak in", %{conn: conn} do
    person = fixture_person()
    other = fixture_person()

    {:ok, _} =
      PhoenixKit.Activity.log(%{
        action: "staff.person_trashed",
        module: "staff",
        resource_type: "staff_person",
        resource_uuid: other.uuid,
        metadata: %{}
      })

    html = open_events(conn, person)

    assert html =~ "No activity recorded for this person yet."
    refute html =~ "Moved to trash"
  end
end
