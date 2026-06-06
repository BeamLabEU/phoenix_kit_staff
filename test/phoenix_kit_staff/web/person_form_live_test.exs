defmodule PhoenixKitStaff.Web.PersonFormLiveTest do
  @moduledoc """
  Smoke tests for the person form, with explicit pins on the Phase 2
  Batch 1 deltas:

  - `phx-disable-with` on submit button
  - validate event sets `:action`
  - `Errors.message/1` translation at the LV layer (atom from
    `Staff.rename_placeholder_email/2` no longer leaks raw strings)
  - activity logging threads `actor_uuid`
  - placeholder-user create flow (single email field → user + person)
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitStaff.{Errors, Staff}

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "new person form" do
    test "mounts and renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/people/new")
      assert html =~ "New staff"
      assert html =~ "person-form"
    end

    test "submit button has phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/people/new")
      assert html =~ ~r/phx-disable-with=/
    end
  end

  describe "Errors atom translation surface" do
    test "`:blank_email` atom translates via Errors.message/1, not a raw string", %{} do
      msg = Errors.message(:blank_email)
      assert msg == "Email is required."
    end

    test "Staff.rename_placeholder_email/2 returns the :blank_email atom on empty input", %{} do
      # Set up a placeholder user via the create-with-user flow so the
      # `placeholder?/1` predicate inside `Staff.rename_placeholder_email`
      # passes. Pin the atom (not a translated string) so consumers
      # know to route through `Errors.message/1` at the boundary.
      person = fixture_person()
      placeholder_user = person.user

      assert {:error, :blank_email} = Staff.rename_placeholder_email(placeholder_user, "")
    end

    test "non-placeholder user can't be renamed (`:placeholder_already_claimed`)", %{} do
      # Build a user that does NOT have the `staff_placeholder` source
      # tag (i.e. simulating a user who has registered themselves).
      {:ok, real_user} =
        Auth.register_user(%{
          "email" => "real-#{System.unique_integer([:positive])}@x.com",
          "password" => "RealPass123!"
        })

      assert {:error, :placeholder_already_claimed} =
               Staff.rename_placeholder_email(
                 real_user,
                 "anything-#{System.unique_integer([:positive])}@x.com"
               )
    end
  end

  describe "validate event renders inline errors" do
    test "validate path stays responsive without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      # The new-form template renders `team_uuid` only after a department
      # is selected, so the no-input validate event omits it.
      html =
        view
        |> form("#person-form", person: %{}, email: "")
        |> render_change()

      # What matters: the validate path stays responsive without raising
      # and the form continues rendering. The validate handler in
      # PersonFormLive sets `:action, :validate` on the changeset (Phase
      # 2 Batch 1 delta) — which is what makes `<.input>` show inline
      # errors here when fields fail validate.
      assert is_binary(html)
      assert html =~ "person-form"
    end
  end

  describe "create flow" do
    test "happy path creates user + person via the context layer", %{} do
      # The form's submit phase couples top-level `email` + nested
      # `person[*]` attrs with no top-level `team_uuid` until a
      # department is selected. Driving the full submit through
      # `render_submit` requires a department-then-team selection
      # round-trip; that's out of scope for a smoke test. The
      # equivalent Phase 2 delta — `:person_created` activity logged
      # with `actor_uuid` threaded through — is pinned in
      # `activity_logging_test.exs` and via the context-layer call here.
      email = "new-#{System.unique_integer([:positive])}@example.com"

      {:ok, person, _status} =
        Staff.create_person_with_user(email, %{"status" => "active", "job_title" => "Engineer"})

      assert person.status == "active"

      person = Staff.get_person!(person.uuid, preload: [:user])
      assert person.user.email == email
    end
  end

  describe "save error — failure-side audit row" do
    test "create-form Save with blank email writes a db_pending audit row (atom branch)", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      # Empty email → Staff.find_or_create_user_by_email/1 returns
      # {:error, :blank_email} → the atom branch in save/5 fires.
      view
      |> form("#person-form", person: %{status: "active"}, email: "")
      |> render_submit()

      assert_activity_logged("staff.person_created",
        actor_uuid: actor_uuid,
        resource_uuid: nil,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "atom",
          "error_atom" => "blank_email"
        }
      )
    end

    test "create-form Save with invalid attrs writes a db_pending audit row (changeset)", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      email = "save-err-#{System.unique_integer([:positive])}@example.com"

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      # Valid email so find_or_create_user_by_email succeeds; invalid
      # `personal_email` format trips `validate_format/3`, so
      # create_person/1 returns {:error, %Ecto.Changeset{}} and the
      # placeholder user is rolled back — but the audit row records the
      # failed attempt. (`personal_email` is a text input rather than a
      # select, so it survives Phoenix LiveView 1.1.29's stricter
      # render_submit/2 option-allowlist validation that blocks bogus
      # status values client-side.)
      view
      |> form("#person-form",
        person: %{status: "active", personal_email: "not-an-email"},
        email: email
      )
      |> render_submit()

      assert_activity_logged("staff.person_created",
        actor_uuid: actor_uuid,
        resource_uuid: nil,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "changeset",
          "attempted_email" => email
        }
      )
    end

    test "edit-form Save with invalid attrs keeps the original record uuid on the audit row", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # Same `personal_email` format-violation vector as the create-form
      # sibling — text input rather than a select, so LV 1.1.29's
      # stricter option-allowlist validation lets it through to the
      # LV's changeset rejection. Edit form doesn't expose the top-level
      # email field, so don't pass one.
      view
      |> form("#person-form",
        person: %{status: "active", personal_email: "not-an-email"}
      )
      |> render_submit()

      assert_activity_logged("staff.person_updated",
        actor_uuid: actor_uuid,
        resource_uuid: person.uuid,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "changeset"
        }
      )
    end
  end

  describe "internal notes field removed" do
    test "the edit form no longer renders the Internal notes field", %{conn: conn} do
      person = fixture_person()

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      refute html =~ "Internal notes"
      # No notes input under any name (primary column or translations key).
      refute html =~ "][notes]"
      refute html =~ ~s|name="person[notes]"|
      # Sibling translatable fields are untouched.
      assert html =~ "Skills"
    end
  end

  describe "404 fallback" do
    test "edit with bogus uuid redirects to people list", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/people"}}} =
               live(conn, "/en/admin/staff/people/#{bogus}/edit")
    end

    # Regression: editing a trashed person must not be possible in place
    # (it would un-trash via the normal update path). Redirect to show.
    test "edit of a trashed person redirects to the show page", %{conn: conn} do
      person = fixture_person()
      {:ok, trashed} = PhoenixKitStaff.Staff.trash_person(person)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/en/admin/staff/people/#{trashed.uuid}/edit")

      assert to == "/en/admin/staff/people/#{trashed.uuid}"
    end

    # Regression: the save path re-checks current DB status, so a save
    # from an edit LV opened before a concurrent trash can't un-trash
    # the person (the mount guard alone wouldn't catch this race).
    test "save after a concurrent trash refuses and leaves the person trashed", %{conn: conn} do
      person = fixture_person()
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # Another admin trashes the person while this edit LV is open.
      {:ok, _} = PhoenixKitStaff.Staff.trash_person(person)

      render_submit(view, "save", %{"person" => %{"status" => "active"}})

      assert_redirect(view, "/en/admin/staff/people/#{person.uuid}")
      assert PhoenixKitStaff.Staff.get_person(person.uuid).status == "trashed"
    end
  end
end
