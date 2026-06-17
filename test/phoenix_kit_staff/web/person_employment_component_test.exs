defmodule PhoenixKitStaff.Web.PersonEmploymentComponentTest do
  @moduledoc "Smoke tests for the Employment tab on the person profile."

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.Employments
  alias PhoenixKitStaff.Schemas.Person

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), actor_uuid: scope.user.uuid}
  end

  defp reload(uuid), do: PhoenixKit.RepoHelper.repo().get(Person, uuid)
  defp form_id(person), do: "employment-form-staff-person-employment-#{person.uuid}"

  defp open_employment_tab(conn, person) do
    {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")
    render_click(view, "switch_tab", %{"tab" => "employment"})
    view
  end

  test "the tab leads with the history + an Add button; the form is revealed on demand", %{
    conn: conn
  } do
    person = fixture_person()
    {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

    html = render_click(view, "switch_tab", %{"tab" => "employment"})

    assert html =~ "Add employment"
    assert html =~ "Employment history"
    assert html =~ "No employment recorded yet"
    # The add form is hidden until the user asks for it.
    refute has_element?(view, "##{form_id(person)}")

    view |> element("button[phx-click='show_add_form']") |> render_click()
    assert has_element?(view, "##{form_id(person)}")

    # Cancel closes it again (available in add mode, not just when editing).
    view |> element("button[phx-click='cancel_edit']") |> render_click()
    refute has_element?(view, "##{form_id(person)}")
  end

  test "the add form pre-fills non-date fields from the current span", %{conn: conn} do
    person = fixture_person()

    _span =
      fixture_employment(person.uuid, %{
        "job_title" => "Staff Engineer",
        "employment_type" => "full_time",
        "employment_start_date" => "2020-01-01"
      })

    view = open_employment_tab(conn, person)
    html = view |> element("button[phx-click='show_add_form']") |> render_click()

    # The current role is carried over so adding reads as "update the role"…
    assert html =~ "Carried over from"
    assert html =~ ~s(value="Staff Engineer")
    # …the start date defaults to today (not the prior span's start) so the new
    # open span reads "today – present" instead of being date-less…
    assert html =~ ~s(value="#{Date.to_iso8601(Date.utc_today())}")
    refute html =~ ~s(value="2020-01-01")
  end

  test "adding a span persists it, mirrors onto Person, and logs activity", %{
    conn: conn,
    actor_uuid: actor_uuid
  } do
    person = fixture_person()
    view = open_employment_tab(conn, person)

    # The add form is hidden by default — reveal it first.
    view |> element("button[phx-click='show_add_form']") |> render_click()

    view
    |> form("##{form_id(person)}",
      employment: %{
        employment_type: "full_time",
        job_title: "Engineer",
        employment_start_date: "2021-01-01"
      }
    )
    |> render_submit()

    assert [span] = Employments.list_for_person(person.uuid)
    assert span.job_title == "Engineer"
    assert span.employment_end_date == nil
    # Denormalized onto Person (drives the Overview header).
    assert reload(person.uuid).job_title == "Engineer"

    assert_activity_logged("staff.person_employment_added",
      actor_uuid: actor_uuid,
      resource_uuid: person.uuid
    )
  end

  test "the timeline shows an existing span with a Current badge", %{conn: conn} do
    person = fixture_person()

    _span =
      fixture_employment(person.uuid, %{
        "job_title" => "Senior Dev",
        "employment_type" => "full_time"
      })

    view = open_employment_tab(conn, person)
    html = render(view)

    assert html =~ "Senior Dev"
    assert html =~ "Current"
  end

  test "removing a span deletes it and clears the Person mirror", %{conn: conn} do
    person = fixture_person()
    span = fixture_employment(person.uuid, %{"job_title" => "Dev"})
    assert reload(person.uuid).job_title == "Dev"

    view = open_employment_tab(conn, person)

    view
    |> element("button[phx-click='remove_employment'][phx-value-uuid='#{span.uuid}']")
    |> render_click()

    assert Employments.list_for_person(person.uuid) == []
    assert reload(person.uuid).job_title == nil
  end

  test "the end + remove buttons carry phx-disable-with", %{conn: conn} do
    person = fixture_person()
    span = fixture_employment(person.uuid, %{"job_title" => "Dev"})
    view = open_employment_tab(conn, person)

    assert has_element?(
             view,
             "button[phx-click='end_employment'][phx-value-uuid='#{span.uuid}'][phx-disable-with]"
           )

    assert has_element?(
             view,
             "button[phx-click='remove_employment'][phx-value-uuid='#{span.uuid}'][phx-disable-with]"
           )
  end

  test "a stale remove (span already deleted) still writes a db_pending audit row", %{
    conn: conn,
    actor_uuid: actor_uuid
  } do
    person = fixture_person()
    span = fixture_employment(person.uuid, %{"job_title" => "Dev"})
    view = open_employment_tab(conn, person)

    # Delete via the raw repo (no `:person_employment_changed` broadcast, so the
    # LV doesn't reload and the rendered button's uuid goes stale) — clicking it
    # then drives the `with` else (not-found) error branch.
    PhoenixKit.RepoHelper.repo().delete!(span)

    view
    |> element("button[phx-click='remove_employment'][phx-value-uuid='#{span.uuid}']")
    |> render_click()

    assert_activity_logged("staff.person_employment_removed",
      actor_uuid: actor_uuid,
      resource_uuid: person.uuid,
      metadata: %{"db_pending" => true}
    )
  end
end
