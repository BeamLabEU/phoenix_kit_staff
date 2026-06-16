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

  test "the Employment tab renders the add form + history heading", %{conn: conn} do
    person = fixture_person()
    {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

    html = render_click(view, "switch_tab", %{"tab" => "employment"})

    assert html =~ "Add employment"
    assert html =~ "Employment history"
    assert html =~ "No employment recorded yet"
  end

  test "adding a span persists it, mirrors onto Person, and logs activity", %{
    conn: conn,
    actor_uuid: actor_uuid
  } do
    person = fixture_person()
    view = open_employment_tab(conn, person)

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
end
