defmodule PhoenixKitStaff.Web.DepartmentFormLiveTest do
  @moduledoc """
  Smoke tests pinning the Phase 2 Batch 1 deltas on the department
  form: phx-disable-with on the submit button, validate event sets
  changeset `:action` so `<.input>` renders errors, save flashes
  reach the rendered HTML, activity logging threads `actor_uuid`.
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKitStaff.{Departments, Schemas}

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "new department form" do
    test "mounts and renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/departments/new")
      assert html =~ "New department"
      assert html =~ "department-form"
    end

    test "submit button has phx-disable-with (Phase 2 Batch 1 delta)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/departments/new")
      # Match the saving translation token; quoting is ambiguous but the
      # attribute itself must be present on the submit button.
      assert html =~ ~r/phx-disable-with=/
      assert html =~ "Saving"
    end

    test "validate event sets changeset :action so errors render inline", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/departments/new")

      # Empty name should fail `validate_required`.
      html =
        view
        |> form("#department-form", department: %{name: "", description: "x"})
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "save logs activity with actor_uuid threaded from socket", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, "/en/admin/staff/departments/new")

      name = "Eng-#{System.unique_integer([:positive])}"

      view
      |> form("#department-form", department: %{name: name, description: "Engineering"})
      |> render_submit()

      [dept] =
        Departments.list()
        |> Enum.filter(&(&1.name == name))

      assert_activity_logged("staff.department_created",
        resource_uuid: dept.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"name" => name}
      )
    end
  end

  describe "save error — failure-side audit row" do
    test "create-form Save with invalid changeset writes a db_pending audit row", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, "/en/admin/staff/departments/new")

      # Empty name fails validate_required, so Departments.create/1
      # returns {:error, %Ecto.Changeset{}} — no department row is
      # inserted, but an audit row should still record the attempt.
      view
      |> form("#department-form", department: %{name: "", description: "x"})
      |> render_submit()

      assert_activity_logged("staff.department_created",
        actor_uuid: actor_uuid,
        resource_uuid: nil,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "changeset"
        }
      )
    end

    test "edit-form Save error keeps the original record uuid on the audit row", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      dept = fixture_department(%{"name" => "Editable-#{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}/edit")

      # Clear name to fail validate_required.
      view
      |> form("#department-form", department: %{name: ""})
      |> render_submit()

      assert_activity_logged("staff.department_updated",
        actor_uuid: actor_uuid,
        resource_uuid: dept.uuid,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "changeset"
        }
      )
    end
  end

  describe "edit department form" do
    test "renders existing values", %{conn: conn} do
      dept = fixture_department(%{"name" => "Existing-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}/edit")
      assert html =~ dept.name
      assert html =~ "Edit"
    end

    test "404 for missing uuid redirects with flash", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/departments"}}} =
               live(conn, "/en/admin/staff/departments/#{bogus}/edit")
    end
  end

  describe "logged-out fallback" do
    test "mounting without a scope still renders (Hooks no-op)", %{} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})

      {:ok, _view, html} = live(conn, "/en/admin/staff/departments/new")
      assert html =~ "New department"
    end
  end

  describe "Schema typespec opaque-style — uses Schemas.Department.t() shape" do
    test "name length validation rejects > 255 chars", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/departments/new")

      long_name = String.duplicate("x", 256)

      html =
        view
        |> form("#department-form", department: %{name: long_name})
        |> render_change()

      assert html =~ "should be at most 255"
    end

    test "Department.changeset/2 returns Ecto.Changeset.t(t())", %{} do
      cs = Schemas.Department.changeset(%Schemas.Department{}, %{name: "x"})
      assert %Ecto.Changeset{data: %Schemas.Department{}} = cs
      assert cs.valid?
    end
  end
end
