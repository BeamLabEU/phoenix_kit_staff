defmodule PhoenixKitStaff.Web.MultilangFormsTest do
  @moduledoc """
  What an admin types on a language tab survives the save and reaches the read
  pages, on a host whose Languages module registers dialect codes (`es-ES`).

  The form tests before these each proved one half (the tab code; the read of a
  seeded key). Nothing wrote through a form and read the value back, which is
  where the two halves disagreed.
  """
  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitStaff.{Departments, Employments, Staff}

  @departments "/en/admin/staff/departments"
  @people "/en/admin/staff/people"

  setup %{conn: conn} do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("es-ES")
    on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, "en") end)

    %{conn: put_test_scope(conn, fake_scope()), primary: Multilang.primary_language()}
  end

  # Applies a tab the way the debounced `switch_language` does, without the wait.
  defp open_tab(view, lang) do
    send(view.pid, {:__multilang_apply_lang__, lang})
    render(view)
  end

  defp edit_department(conn, dept) do
    {:ok, view, _html} = live(conn, "#{@departments}/#{dept.uuid}/edit")
    view
  end

  describe "a translation typed in a form" do
    test "reaches the read page of a viewer on that dialect", %{conn: conn, primary: primary} do
      dept = fixture_department(%{"name" => "EngineeringPRIMARY"})
      view = edit_department(conn, dept)

      open_tab(view, "es-ES")

      view
      |> form("#department-form",
        department: %{translations: %{"es-ES" => %{name: "IngenieriaES"}}}
      )
      |> render_submit()

      assert primary != "es-ES"

      {:ok, _view, html} = conn |> put_test_locale("es-ES") |> live(@departments)

      assert html =~ "IngenieriaES"
      refute html =~ "EngineeringPRIMARY"
    end

    test "survives a save from the primary tab", %{conn: conn, primary: primary} do
      dept = fixture_department(%{"name" => "Engineering"})
      view = edit_department(conn, dept)

      open_tab(view, "es-ES")

      view
      |> form("#department-form",
        department: %{translations: %{"es-ES" => %{name: "IngenieriaES"}}}
      )
      |> render_change()

      open_tab(view, primary)

      view |> form("#department-form", department: %{name: "Engineering"}) |> render_submit()

      assert Departments.get(dept.uuid).translations["es-ES"]["name"] == "IngenieriaES"
    end

    test "survives a primary-tab validate before the save", %{conn: conn, primary: primary} do
      dept = fixture_department(%{"name" => "Engineering"})
      view = edit_department(conn, dept)

      open_tab(view, "es-ES")

      view
      |> form("#department-form",
        department: %{translations: %{"es-ES" => %{name: "IngenieriaES"}}}
      )
      |> render_change()

      open_tab(view, primary)

      view |> form("#department-form", department: %{name: "Renamed"}) |> render_change()
      view |> form("#department-form", department: %{name: "Renamed"}) |> render_submit()

      dept = Departments.get(dept.uuid)
      assert dept.name == "Renamed"
      assert dept.translations["es-ES"]["name"] == "IngenieriaES"
    end
  end

  describe "a save that changed no translation" do
    test "leaves one written since the form opened", %{conn: conn, primary: primary} do
      dept = fixture_department(%{"name" => "Engineering"})
      view = edit_department(conn, dept)
      open_tab(view, primary)

      newer = %{"es-ES" => %{"name" => "IngenieriaES"}}
      {:ok, _dept} = Departments.update(dept, %{"translations" => newer})

      view |> form("#department-form", department: %{name: "Research"}) |> render_submit()

      assert %{name: "Research", translations: ^newer} = Departments.get(dept.uuid)
    end
  end

  describe "a language sharing the primary's base" do
    setup %{conn: conn} do
      {:ok, _} = Languages.add_language("en-GB")

      dept =
        fixture_department(%{
          "name" => "ColorPRIMARY",
          "translations" => %{"en-GB" => %{"name" => "ColourGB"}}
        })

      %{conn: conn, dept: dept}
    end

    test "reads its own override", %{conn: conn} do
      {:ok, _view, html} = conn |> put_test_locale("en-GB") |> live(@departments)

      assert html =~ "ColourGB"
    end

    test "does not replace the primary column for a primary viewer", %{
      conn: conn,
      primary: primary
    } do
      {:ok, _view, html} = conn |> put_test_locale(primary) |> live(@departments)

      assert html =~ "ColorPRIMARY"
      refute html =~ "ColourGB"
    end
  end

  describe "clearing a field" do
    test "on a language tab removes its override", %{conn: conn} do
      dept =
        fixture_department(%{
          "name" => "Engineering",
          "description" => "Builds things",
          "translations" => %{
            "es-ES" => %{"name" => "IngenieriaES", "description" => "DescripcionES"}
          }
        })

      view = edit_department(conn, dept)
      open_tab(view, "es-ES")

      view
      |> form("#department-form",
        department: %{translations: %{"es-ES" => %{name: "", description: "DescripcionES"}}}
      )
      |> render_submit()

      assert Departments.get(dept.uuid).translations == %{
               "es-ES" => %{"description" => "DescripcionES"}
             }
    end

    test "of a language's last override removes the language", %{conn: conn} do
      dept =
        fixture_department(%{
          "name" => "Engineering",
          "translations" => %{"es-ES" => %{"name" => "IngenieriaES"}}
        })

      view = edit_department(conn, dept)
      open_tab(view, "es-ES")

      view
      |> form("#department-form", department: %{translations: %{"es-ES" => %{name: ""}}})
      |> render_submit()

      assert Departments.get(dept.uuid).translations == %{}
    end

    test "of the last override sticks when the save comes from the primary tab", %{
      conn: conn,
      primary: primary
    } do
      dept =
        fixture_department(%{
          "name" => "Engineering",
          "translations" => %{"es-ES" => %{"name" => "IngenieriaES"}}
        })

      view = edit_department(conn, dept)
      open_tab(view, "es-ES")

      view
      |> form("#department-form", department: %{translations: %{"es-ES" => %{name: ""}}})
      |> render_change()

      open_tab(view, primary)

      view |> form("#department-form", department: %{name: "Engineering"}) |> render_submit()

      assert Departments.get(dept.uuid).translations == %{}
    end

    test "on the primary tab sticks when the save comes from a language tab", %{
      conn: conn,
      primary: primary
    } do
      dept = fixture_department(%{"name" => "Engineering", "description" => "Builds things"})
      view = edit_department(conn, dept)

      open_tab(view, primary)

      view
      |> form("#department-form", department: %{name: "Engineering", description: ""})
      |> render_change()

      open_tab(view, "es-ES")
      view |> form("#department-form") |> render_submit()

      assert Departments.get(dept.uuid).description == nil
    end
  end

  describe "the person form" do
    setup %{conn: conn} do
      person = fixture_person(%{"bio" => "Original"})
      {:ok, view, _html} = live(conn, "#{@people}/#{person.uuid}/edit")
      %{person: person, view: view}
    end

    defp open_span(person, title, translations \\ %{}) do
      fixture_employment(person.uuid, %{
        "job_title" => title,
        "employment_type" => "full_time",
        "employment_start_date" => "2024-01-01",
        "translations" => translations
      })
    end

    test "does not write back a title the open span changed while it was open", ctx do
      open_span(ctx.person, "Dev")
      {:ok, view, _html} = live(ctx.conn, "#{@people}/#{ctx.person.uuid}/edit")

      fixture_employment(ctx.person.uuid, %{
        "job_title" => "Lead",
        "employment_type" => "full_time",
        "employment_start_date" => "2025-01-01"
      })

      view |> form("#person-form", person: %{bio: "Updated"}) |> render_submit()

      person = Staff.get_person(ctx.person.uuid)
      assert person.bio == "Updated"
      assert person.job_title == "Lead"
    end

    test "keeps the span's title override on a save from a language tab", ctx do
      open_span(ctx.person, "Lead", %{"es-ES" => %{"job_title" => "JefeES"}})

      open_tab(ctx.view, "es-ES")

      ctx.view
      |> form("#person-form", person: %{translations: %{"es-ES" => %{bio: "BiografiaES"}}})
      |> render_submit()

      assert Staff.get_person(ctx.person.uuid).translations["es-ES"] == %{
               "job_title" => "JefeES",
               "bio" => "BiografiaES"
             }
    end

    test "removes a blanked last bio override on a save from the primary tab", ctx do
      {:ok, _person} =
        Staff.update_person(ctx.person, %{
          "translations" => %{"es-ES" => %{"bio" => "BiografiaES"}}
        })

      {:ok, view, _html} = live(ctx.conn, "#{@people}/#{ctx.person.uuid}/edit")
      open_tab(view, "es-ES")

      view
      |> form("#person-form", person: %{translations: %{"es-ES" => %{bio: ""}}})
      |> render_change()

      open_tab(view, ctx.primary)

      view |> form("#person-form", person: %{bio: "Original"}) |> render_submit()

      assert Staff.get_person(ctx.person.uuid).translations == %{}
    end

    test "leaves a bio override written since it opened when it changed none", ctx do
      open_tab(ctx.view, ctx.primary)

      newer = %{"es-ES" => %{"bio" => "BiografiaES"}}
      {:ok, _person} = Staff.update_person(ctx.person, %{"translations" => newer})

      ctx.view |> form("#person-form", person: %{bio: "Updated"}) |> render_submit()

      assert %{bio: "Updated", translations: ^newer} = Staff.get_person(ctx.person.uuid)
    end

    test "ignores crafted values for the server-owned columns", ctx do
      dept = fixture_department()

      other = fixture_person()

      ctx.view
      |> form("#person-form")
      |> render_submit(%{
        "person" => %{
          "primary_department_uuid" => dept.uuid,
          "job_title" => "Crafted",
          "user_uuid" => other.user_uuid
        }
      })

      person = Staff.get_person(ctx.person.uuid)
      assert person.primary_department_uuid == nil
      assert person.job_title == nil
      assert person.user_uuid == ctx.person.user_uuid
    end
  end

  describe "the add-employment form" do
    defp add_span(conn, person, attrs) do
      {:ok, view, _html} = live(conn, "#{@people}/#{person.uuid}")
      render_click(view, "switch_tab", %{"tab" => "employment"})
      view |> element("button[phx-click='show_add_form']") |> render_click()

      view
      |> form("#employment-form-staff-person-employment-#{person.uuid}", employment: attrs)
      |> render_submit()
    end

    setup do
      person = fixture_person()

      span =
        fixture_employment(person.uuid, %{
          "job_title" => "Lead",
          "employment_type" => "full_time",
          "employment_start_date" => "2020-01-01",
          "work_location" => "Old office",
          "translations" => %{"es-ES" => %{"job_title" => "JefeES"}}
        })

      %{person: person, span: span}
    end

    test "carries a work location the form did not render", %{conn: conn, person: person} do
      add_span(conn, person, %{employment_start_date: "2024-06-01"})

      assert Employments.current_for_person(person.uuid).work_location == "Old office"
      assert Staff.get_person(person.uuid).work_location == "Old office"
    end

    test "carries the title's translations when the title is kept", %{conn: conn, person: person} do
      add_span(conn, person, %{employment_start_date: "2024-06-01"})

      assert Employments.current_for_person(person.uuid).translations["es-ES"]["job_title"] ==
               "JefeES"

      assert Staff.get_person(person.uuid).translations["es-ES"]["job_title"] == "JefeES"
    end

    test "drops them when the title changes", %{conn: conn, person: person} do
      add_span(conn, person, %{employment_start_date: "2024-06-01", job_title: "Director"})

      assert Employments.current_for_person(person.uuid).translations == %{}
    end
  end
end
