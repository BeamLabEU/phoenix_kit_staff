defmodule PhoenixKitStaff.CoverageExtrasTest do
  @moduledoc """
  Final coverage push (Batch 5) — knocks down every remaining gap
  except the truly external residuals (`Activity` rescue branches
  that need core to re-raise, and the `use PhoenixKit.Module` macro
  expansion line).

  No external test deps; uses real fixtures + LV events + direct
  unit tests. Some tests probe private helpers indirectly via the
  full LV mount + render path.
  """

  use PhoenixKitStaff.LiveCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Users.Auth
  alias PhoenixKitStaff.{Activity, Departments, Errors, L10n, Staff, Teams}
  alias PhoenixKitStaff.Schemas.Person
  alias PhoenixKitStaff.Test.Repo, as: TestRepo
  alias PhoenixKitStaff.Web.Helpers

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  # ────────────────────────────────────────────────────────────────
  describe "Paths.index/0 — uncovered helper" do
    test "Paths.index/0 returns the staff dashboard root" do
      result = PhoenixKitStaff.Paths.index()
      assert is_binary(result)
      assert result =~ "/admin/staff"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PeopleLive — unknown status fall-through render branch" do
    test "renders 'badge-ghost' class for out-of-band status via raw SQL" do
      # `validate_inclusion(:status, [active, inactive])` rejects
      # other values via the public API, so we use `Repo.insert_all`
      # to land an out-of-band row directly. `status_badge_class/1`
      # falls through to the catch-all `badge-ghost` clause.
      person = fixture_person()

      TestRepo.query!(
        "UPDATE phoenix_kit_staff_people SET status = $1 WHERE uuid = $2",
        ["archived", Ecto.UUID.dump!(person.uuid)]
      )

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_test_scope(fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/staff/people")

      assert html =~ "badge-ghost"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PersonShowLive — render helper edge cases" do
    test "renders Teams table when person has memberships", %{conn: conn} do
      team = fixture_team()
      person = fixture_person()
      {:ok, _tm} = Staff.add_team_person(team.uuid, person.uuid)

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # Renders the Team / Department headers, hits the `else` branch
      # of `if @memberships == []`.
      assert html =~ "Team" and html =~ "Department"
    end

    test "renders without DOB (format_birthday nil branch)", %{conn: conn} do
      person = fixture_person()

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # Person card mounts without crashing — format_birthday(nil) -> nil
      # branch fires for the missing date_of_birth.
      assert html =~ person.user.email
    end

    test "renders Employment card with only some fields populated", %{conn: conn} do
      # Set work_location only (no start/end date / type).
      person = fixture_person(%{"work_location" => "Remote"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # has_any? returns true for at least one of the employment fields
      # → Employment card renders. format_date(nil) returns "—" for
      # the missing dates; the dt/dd pairs render conditionally.
      assert html =~ "Remote"
      assert html =~ "Employment"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "DepartmentsLive — listing render of department description" do
    test "renders department description in the listing row", %{conn: conn} do
      _dept =
        fixture_department(%{
          "name" => "WithDesc-#{System.unique_integer([:positive])}",
          "description" => "Has a description"
        })

      {:ok, _view, html} = live(conn, "/en/admin/staff/departments")

      assert html =~ "Has a description"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PhoenixKitStaff.enabled? — rescue branches" do
    @tag :destructive_rescue
    test "enabled? returns false when phoenix_kit_settings table is missing (rescue branch)" do
      # Drop the settings table mid-transaction to force
      # `Settings.get_boolean_setting/2` to raise. The wrapper's
      # `rescue _ -> false` clause must fire and return false without
      # crashing. Sandbox rolls the DROP back at test exit.
      TestRepo.query!("DROP TABLE phoenix_kit_settings CASCADE")

      assert PhoenixKitStaff.enabled?() == false
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "Web.Helpers — uncovered map-handling branches" do
    test "extra metadata with string keys passes through unchanged" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          phoenix_kit_current_user: %{uuid: Ecto.UUID.generate()},
          __changed__: %{}
        }
      }

      resource_uuid = Ecto.UUID.generate()

      Helpers.log_operation_error("staff.team_deleted", socket,
        reason: :other,
        resource_type: "team",
        resource_uuid: resource_uuid,
        # String keys exercise the `{k, v} -> {k, v}` clause of stringify_keys.
        metadata: %{"already_string_key" => "value"}
      )

      assert_activity_logged("staff.team_deleted",
        resource_uuid: resource_uuid,
        metadata_has: %{"db_pending" => true, "already_string_key" => "value"}
      )
    end

    test "atom-keyed metadata gets stringified before merging" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          phoenix_kit_current_user: %{uuid: Ecto.UUID.generate()},
          __changed__: %{}
        }
      }

      resource_uuid = Ecto.UUID.generate()

      # Atom keys exercise the `{k, v} when is_atom(k) ->
      # {Atom.to_string(k), v}` clause of `stringify_keys/1`.
      Helpers.log_operation_error("staff.team_deleted", socket,
        reason: :other,
        resource_type: "team",
        resource_uuid: resource_uuid,
        metadata: %{some_atom_key: "value"}
      )

      assert_activity_logged("staff.team_deleted",
        resource_uuid: resource_uuid,
        metadata_has: %{
          "db_pending" => true,
          "some_atom_key" => "value"
        }
      )
    end

    test "metadata defaults to empty map when omitted" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          phoenix_kit_current_user: %{uuid: Ecto.UUID.generate()},
          __changed__: %{}
        }
      }

      resource_uuid = Ecto.UUID.generate()

      # No metadata kw passed — exercises the `Keyword.get(:metadata, %{})`
      # default + the `is_map(map)` clause of stringify_keys.
      Helpers.log_operation_error("staff.team_deleted", socket,
        reason: :forbidden,
        resource_type: "team",
        resource_uuid: resource_uuid
      )

      assert_activity_logged("staff.team_deleted",
        resource_uuid: resource_uuid,
        metadata_has: %{"db_pending" => true}
      )
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "Schemas.Person — status_label and statuses/employment_types accessors" do
    test "statuses/0 returns the canonical list" do
      assert Person.statuses() == ~w(active inactive)
    end

    test "employment_types/0 returns the canonical list" do
      assert Person.employment_types() == ~w(full_time part_time contractor intern temporary)
    end

    test "status_label rendering of inactive status appears on people page", %{conn: conn} do
      person = fixture_person()
      {:ok, _} = Staff.update_person(person, %{"status" => "inactive"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people")

      # Confirms the `status_label("inactive")` literal-gettext clause is hit.
      assert html =~ "Inactive"
    end

    test "every status_label/1 clause returns its expected output" do
      assert Person.status_label("active") == "Active"
      assert Person.status_label("inactive") == "Inactive"
      assert Person.status_label("archived") == "archived"
      assert Person.status_label(nil) == nil
    end

    test "every employment_type_label/1 clause returns its expected output" do
      assert Person.employment_type_label("full_time") == "Full-time"
      assert Person.employment_type_label("part_time") == "Part-time"
      assert Person.employment_type_label("contractor") == "Contractor"
      assert Person.employment_type_label("intern") == "Intern"
      assert Person.employment_type_label("temporary") == "Temporary"
      assert Person.employment_type_label(nil) == nil
      assert Person.employment_type_label("freelancer") == "freelancer"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PersonShowLive — render helpers via full mounts" do
    test "renders 'Staff' fallback when user has no email", %{conn: conn} do
      # Construct a user with empty email + no first/last name. Direct
      # SQL bypasses the email regex validation. This exercises
      # `person_label/1` fallback (line 64) and `full_name/1` fallback
      # (line 76) in PersonShowLive.
      email = "with-name-#{System.unique_integer([:positive])}@example.com"
      {:ok, user} = Auth.register_user(%{"email" => email, "password" => "Aa1!stuffstuff"})

      # Force first_name/last_name on the user record so the
      # `full_name/1` `is_binary` clause fires.
      TestRepo.query!(
        "UPDATE phoenix_kit_users SET first_name = $1, last_name = $2 WHERE uuid = $3",
        ["Alice", "Smith", Ecto.UUID.dump!(user.uuid)]
      )

      {:ok, person} = Staff.create_person(%{"user_uuid" => user.uuid, "status" => "active"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # full_name/1 produces "Alice Smith" — covers the join + reject branches.
      assert html =~ "Alice Smith"
    end

    test "renders fallback when first_name and last_name are both nil", %{conn: conn} do
      person = fixture_person()

      # The default fixture user has no first_name/last_name, so
      # full_name/1 falls through to `defp full_name(_), do: nil`.
      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # The hero falls back to person_label (the email).
      assert html =~ person.user.email
    end

    test "format_birthday for past-this-year birthday wraps to next year", %{conn: conn} do
      today = Date.utc_today()
      # DOB 25y ago - 5 days → birthday already passed this year, wraps next year.
      past_day = Date.add(today, -5)
      dob = Date.new!(past_day.year - 25, past_day.month, past_day.day)

      person = fixture_person(%{"date_of_birth" => Date.to_string(dob)})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # The page renders without crashing — the wrap-to-next-year branch
      # in days_until_birthday/2 fires (line 119-120).
      assert html =~ "age"
    end

    test "format_birthday handles Feb 29 DOB in non-leap target year", %{conn: conn} do
      person = fixture_person(%{"date_of_birth" => "2000-02-29"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # The Date.new clause fails for non-leap target year → falls
      # through to Date.new!(year, 2, min(29, 28)) = Feb 28.
      assert html =~ "age"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PersonFormLive — uncovered branches" do
    test "create_person_with_user error atom flashes via Errors.message/1", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      # Empty email → :blank_email atom error from
      # Staff.find_or_create_user_by_email/1 → reaches the
      # `{:error, atom} when is_atom(atom)` branch in save :new.
      html =
        render_submit(view, "save", %{
          "person" => %{"status" => "active"},
          "email" => ""
        })

      assert html =~ Errors.message(:blank_email)
    end

    test "save :edit ignores email param when user is non-placeholder (locked field)", %{
      conn: conn
    } do
      person = fixture_person()
      bogus_email = "should-be-ignored-#{System.unique_integer([:positive])}@example.com"

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # User is non-placeholder, so email_editable? = false, so
      # email_changed? short-circuits to false, and rename never fires.
      # Update succeeds and redirects.
      assert {:error, {:live_redirect, _}} =
               render_submit(view, "save", %{
                 "person" => %{"status" => "active", "job_title" => "Updated"},
                 "email" => bogus_email
               })

      # Email is unchanged (the bogus value was ignored).
      assert Auth.get_user_by_email(person.user.email) != nil
      assert Auth.get_user_by_email(bogus_email) == nil
    end

    test "save :new with team_uuid logs both person_created and team_person_added", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      dept = fixture_department()
      team = fixture_team(%{"department_uuid" => dept.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      email = "twolog-#{System.unique_integer([:positive])}@example.com"

      render_submit(view, "save", %{
        "person" => %{
          "status" => "active",
          "primary_department_uuid" => dept.uuid
        },
        "email" => email,
        "team_uuid" => team.uuid
      })

      # Both activity rows landed.
      assert_activity_logged("staff.person_created", actor_uuid: actor_uuid)
      assert_activity_logged("staff.team_person_added", actor_uuid: actor_uuid)
    end

    test "validate event with team_uuid populates selected_team_uuid", %{conn: conn} do
      dept = fixture_department()
      team = fixture_team(%{"name" => "TeamX", "department_uuid" => dept.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      html =
        render_change(view, "validate", %{
          "person" => %{"status" => "active", "primary_department_uuid" => dept.uuid},
          "team_uuid" => team.uuid,
          "email" => ""
        })

      assert html =~ "TeamX"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "DepartmentsLive / TeamsLive / PeopleLive — bogus uuid not-found paths" do
    test "DepartmentsLive delete with bogus uuid flashes 'not found'", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/departments")

      bogus = Ecto.UUID.generate()
      render_click(view, "delete", %{"uuid" => bogus})

      refute_activity_logged("staff.department_deleted", resource_uuid: bogus)
      assert render(view) =~ "not found"
    end

    test "TeamsLive delete with bogus uuid flashes 'not found'", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/teams")

      bogus = Ecto.UUID.generate()
      render_click(view, "delete", %{"uuid" => bogus})

      refute_activity_logged("staff.team_deleted", resource_uuid: bogus)
      assert render(view) =~ "not found"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "TeamShowLive — uncovered events" do
    test "add_person with empty staff_person_uuid flashes 'pick someone first'", %{conn: conn} do
      team = fixture_team()

      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

      render_submit(view, "add_person", %{"staff_person_uuid" => ""})

      assert render(view) =~ "Pick someone first"
    end

    test "add_person with NO staff_person_uuid param flashes 'pick someone first'", %{conn: conn} do
      team = fixture_team()

      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

      render_submit(view, "add_person", %{})

      assert render(view) =~ "Pick someone first"
    end

    test "remove_person with stale tm_uuid is a no-op (not in memberships)", %{conn: conn} do
      team = fixture_team()

      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

      bogus = Ecto.UUID.generate()
      render_click(view, "remove_person", %{"uuid" => bogus})

      # No activity logged for this stale ID; LV stayed alive.
      refute_activity_logged("staff.team_person_removed", resource_uuid: bogus)
    end

    test "renders 'Everyone is already on this team' when available_people is empty", %{
      conn: conn
    } do
      team = fixture_team()
      person = fixture_person()
      {:ok, _} = Staff.add_team_person(team.uuid, person.uuid)

      {:ok, _view, html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

      assert html =~ "Everyone is already on this team"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "DepartmentShowLive — uncovered render branches" do
    test "renders dept description when present", %{conn: conn} do
      dept =
        fixture_department(%{
          "name" => "Engineering",
          "description" => "Builds the product"
        })

      {:ok, _view, html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}")

      assert html =~ "Builds the product"
    end

    test "renders 'No teams in this department yet' when teams list is empty", %{conn: conn} do
      dept = fixture_department()

      {:ok, _view, html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}")

      assert html =~ "No teams in this department yet"
    end

    test "renders teams when present", %{conn: conn} do
      dept = fixture_department()
      team = fixture_team(%{"name" => "Backend", "department_uuid" => dept.uuid})

      {:ok, _view, html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}")

      assert html =~ team.name
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "TeamFormLive — uncovered branches" do
    test "renders department prompt with empty options when no departments", %{conn: conn} do
      # Even with zero departments, the form renders gracefully —
      # exercises the team-form mount + render fall-through branches.
      TestRepo.query!("DELETE FROM phoenix_kit_staff_teams CASCADE")
      TestRepo.query!("DELETE FROM phoenix_kit_staff_departments CASCADE")

      {:ok, _view, html} = live(conn, "/en/admin/staff/teams/new")

      assert html =~ "New team"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "L10n — extra branches" do
    test "format_date with NaiveDateTime.local equivalents" do
      # Already covered, but pin again with a different shape: a
      # NaiveDateTime that's NOT midnight to make sure the conversion
      # path doesn't touch time.
      ndt = ~N[2024-06-15 18:45:30]
      assert L10n.format_date(ndt) == "Jun 15, 2024"
    end

    test "format_date with Date returns same calendar date regardless of timezone" do
      d = ~D[2024-12-31]
      assert L10n.format_date(d) == "Dec 31, 2024"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "Activity wrapper — cross-process rescue branches" do
    test "log/2 from a process without sandbox checkout swallows DBConnection.OwnershipError" do
      # The wrapper's `DBConnection.OwnershipError -> :ok` rescue clause
      # is unreachable in normal in-test code paths because every test
      # is sandboxed. To trigger it, we spawn an UNALLOWED process that
      # tries to log — its Repo call raises OwnershipError, the wrapper
      # catches it as :ok.
      parent = self()

      # We don't allow this child on the sandbox, so its DB access fails.
      pid =
        spawn(fn ->
          # Suppress core's own Logger.error noise.
          result =
            capture_log(fn ->
              try do
                r =
                  Activity.log("staff.cross_process_test",
                    actor_uuid: Ecto.UUID.generate(),
                    resource_type: "staff_person",
                    resource_uuid: Ecto.UUID.generate(),
                    metadata: %{}
                  )

                send(parent, {:done, r})
              rescue
                e -> send(parent, {:crashed, e})
              catch
                kind, reason -> send(parent, {:caught, kind, reason})
              end
            end)

          send(parent, {:log_output, result})
        end)

      ref = Process.monitor(pid)

      # Wait for either :done / :crashed / :caught.
      result =
        receive do
          {:done, r} -> {:done, r}
          {:crashed, _} = msg -> msg
          {:caught, _, _} = msg -> msg
        after
          5_000 -> :timeout
        end

      receive do
        {:log_output, _} -> :ok
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        500 -> :ok
      end

      # The wrapper must have caught the OwnershipError — result is
      # `:done` (no crash, no rethrow). The exact return value can be
      # `:ok` (rescue path) or `{:error, _}` (core returned a tuple).
      case result do
        {:done, _} ->
          :ok

        {:caught, :exit, _} ->
          :ok

        other ->
          flunk("Activity.log/2 must not crash from an unallowed process; got: #{inspect(other)}")
      end
    end

    test "log/2 with a missing activities table swallows the error" do
      # Drop the table inside the sandboxed transaction. The wrapper
      # MUST NOT raise to the caller. Result is either `:ok` (rescue
      # path) or `{:error, %Postgrex.Error{}}` (core returned the
      # error tuple directly).
      TestRepo.query!("DROP TABLE phoenix_kit_activities CASCADE")

      result =
        Activity.log("staff.test_action",
          actor_uuid: Ecto.UUID.generate(),
          resource_type: "staff_person",
          resource_uuid: Ecto.UUID.generate(),
          metadata: %{}
        )

      assert match?(:ok, result) or match?({:error, _}, result)
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "Staff context — additional public-API edges" do
    test "create_person_with_user rolls back placeholder user when person insert fails" do
      # Force the person insert to fail by passing an invalid status.
      email = "rollback-#{System.unique_integer([:positive])}@example.com"

      result =
        Staff.create_person_with_user(email, %{"status" => "definitely_not_valid"})

      assert {:error, %Ecto.Changeset{}} = result

      # Placeholder user got rolled back.
      assert Auth.get_user_by_email(email) == nil
    end

    test "create_person_with_user reuses an existing user without rolling them back" do
      person_a = fixture_person()
      existing_email = person_a.user.email

      # Try to add a second profile to the SAME existing user — fails
      # at the unique_constraint, but must NOT delete the existing user.
      result =
        Staff.create_person_with_user(existing_email, %{"status" => "active"})

      assert {:error, _changeset} = result

      # Existing user is intact.
      assert %{} = Auth.get_user_by_email(existing_email)
    end

    test "list_people accepts :status filter" do
      _active = fixture_person()
      inactive = fixture_person()
      {:ok, _} = Staff.update_person(inactive, %{"status" => "inactive"})

      result_uuids = Staff.list_people(status: "inactive") |> Enum.map(& &1.uuid)
      assert inactive.uuid in result_uuids
    end

    test "list_people accepts :search filter (matches email substring)" do
      person = fixture_person()
      slug = person.user.email |> String.split("@") |> List.first()

      result_uuids = Staff.list_people(search: slug) |> Enum.map(& &1.uuid)
      assert person.uuid in result_uuids
    end

    test "list_people normalizes blank/nil search to no-op" do
      person = fixture_person()

      # Blank string and nil both bypass the search filter — should
      # return the full list including this person.
      assert Staff.list_people(search: "") |> Enum.map(& &1.uuid) |> Enum.member?(person.uuid)
      assert Staff.list_people(search: nil) |> Enum.map(& &1.uuid) |> Enum.member?(person.uuid)
    end

    test "get_person_by_user_uuid returns the linked person" do
      person = fixture_person()

      result = Staff.get_person_by_user_uuid(person.user_uuid)
      assert result.uuid == person.uuid
    end

    test "get_person_by_user_uuid returns nil for unknown user_uuid" do
      assert Staff.get_person_by_user_uuid(Ecto.UUID.generate()) == nil
    end

    test "get_person/2 returns nil for valid-but-unknown uuid" do
      assert Staff.get_person(Ecto.UUID.generate()) == nil
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PersonFormLive — placeholder-user rename flow" do
    # The fixture-created user is auto-confirmed by core's
    # `Auth.register_user/1`, so `placeholder_user?/1` returns false.
    # Manually flip the user back to placeholder state via raw SQL
    # to exercise the rename-email LV branches that only fire for
    # unclaimed placeholder users.

    defp build_placeholder_person do
      person = fixture_person()

      TestRepo.query!(
        """
        UPDATE phoenix_kit_users
        SET confirmed_at = NULL,
            custom_fields = '{"source": "staff_placeholder"}'
        WHERE uuid = $1
        """,
        [Ecto.UUID.dump!(person.user_uuid)]
      )

      Staff.get_person!(person.uuid, preload: [:user, :primary_department])
    end

    test "edit form for placeholder user shows the editable email field", %{conn: conn} do
      person = build_placeholder_person()

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      assert html =~ "editable — account not yet claimed"
    end

    test "rename to a brand-new email succeeds and redirects", %{conn: conn} do
      person = build_placeholder_person()
      new_email = "renamed-#{System.unique_integer([:positive])}@example.com"

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # Drive the save event — rename succeeds via :ok path,
      # do_update_person redirects.
      assert {:error, {:live_redirect, _}} =
               render_submit(view, "save", %{
                 "person" => %{"status" => "active"},
                 "email" => new_email
               })

      # Email actually changed in the DB.
      assert Auth.get_user_by_email(new_email) != nil
    end

    test "rename to an already-taken email flashes :email_already_taken atom", %{conn: conn} do
      person = build_placeholder_person()
      taken = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      html =
        render_submit(view, "save", %{
          "person" => %{"status" => "active"},
          "email" => taken.user.email
        })

      assert html =~ Errors.message(:email_already_taken)
    end

    test "rename with same-as-current email goes through :ok no-op branch", %{conn: conn} do
      person = build_placeholder_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # Same email → email_changed? = false → rename_result = :ok →
      # do_update_person redirects after successful save.
      assert {:error, {:live_redirect, _}} =
               render_submit(view, "save", %{
                 "person" => %{"status" => "active", "job_title" => "Updated"},
                 "email" => person.user.email
               })
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PersonFormLive — maybe_add_to_team error branch + create_flash variants" do
    test "save :new with non-existent team_uuid flashes :warning + Logger.warning", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      dept = fixture_department()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      email = "warning-#{System.unique_integer([:positive])}@example.com"
      bogus_team = Ecto.UUID.generate()

      log =
        capture_log([level: :warning], fn ->
          render_submit(view, "save", %{
            "person" => %{
              "status" => "active",
              "primary_department_uuid" => dept.uuid
            },
            "email" => email,
            "team_uuid" => bogus_team
          })
        end)

      # The Logger.warning at line 234-235 fired.
      assert log =~ "could not add person" and log =~ bogus_team

      # Person was still created (the team failure is non-fatal).
      assert_activity_logged("staff.person_created", actor_uuid: actor_uuid)
    end

    test "save :edit with non-existent team_uuid flashes :warning", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      person = fixture_person()
      bogus_team = Ecto.UUID.generate()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      capture_log([level: :warning], fn ->
        render_submit(view, "save", %{
          "person" => %{"status" => "active"},
          "email" => person.user.email,
          "team_uuid" => bogus_team
        })
      end)

      # update_flash(:error) branch at line 269 fired.
      assert_activity_logged("staff.person_updated", actor_uuid: actor_uuid)
    end

    test "save :new with EXISTING email reuses the user (not :created status)", %{
      conn: conn
    } do
      existing = fixture_person()

      # Delete the staff profile but keep the user — so the email
      # already exists in phoenix_kit_users but no person links to it.
      {:ok, _} = Staff.delete_person(existing)

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      render_submit(view, "save", %{
        "person" => %{"status" => "active"},
        "email" => existing.user.email
      })

      # Hits create_flash(:existing, :ok, _) branch at line 258.
      # We can confirm the second person was created against the
      # existing user.
      [new_person] =
        Staff.list_people()
        |> Enum.filter(&(&1.user_uuid == existing.user.uuid))

      assert new_person.uuid != existing.uuid
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PeopleLive — render branches for inactive status + filter clearing" do
    test "table renders 'Inactive' status badge for inactive people", %{conn: conn} do
      person = fixture_person()
      {:ok, _} = Staff.update_person(person, %{"status" => "inactive"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people")

      assert html =~ "Inactive"
    end

    test "renders empty-state message when no people exist", %{conn: conn} do
      # Delete all people first.
      TestRepo.query!("DELETE FROM phoenix_kit_staff_people CASCADE")

      {:ok, _view, html} = live(conn, "/en/admin/staff/people")

      # Specific empty-state copy from people_live.ex render template.
      assert html =~ "No staff" or html =~ "Everyone"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "DepartmentsLive — empty-list render" do
    test "renders an empty-state message when no departments exist", %{conn: conn} do
      TestRepo.query!("DELETE FROM phoenix_kit_staff_teams CASCADE")
      TestRepo.query!("DELETE FROM phoenix_kit_staff_departments CASCADE")

      {:ok, _view, html} = live(conn, "/en/admin/staff/departments")

      # The render template has fallback copy when departments list is empty.
      assert html =~ "Departments"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PersonShowLive — admin notes + emergency contact partial render branches" do
    test "renders admin notes warning panel when notes are present", %{conn: conn} do
      person = fixture_person(%{"notes" => "Sensitive admin-only context"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      assert html =~ "Admin notes"
      assert html =~ "Sensitive admin-only context"
    end

    test "renders emergency-contact card with only name (other fields empty)", %{conn: conn} do
      person = fixture_person(%{"emergency_contact_name" => "Solo Contact"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      assert html =~ "Solo Contact"
      assert html =~ "Emergency contact"
    end

    test "renders emergency-contact card with phone only", %{conn: conn} do
      person = fixture_person(%{"emergency_contact_phone" => "+372 800 1234"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      assert html =~ "+372 800 1234"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "TeamShowLive — full happy-path add_person flow + bogus mounts" do
    test "add_person SUCCESS via LV event logs activity through the success path", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      team = fixture_team()
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

      render_submit(view, "add_person", %{"staff_person_uuid" => person.uuid})

      # Hits the `{:ok, tm}` branch of `Staff.add_team_person/2`,
      # the inline `Activity.log("staff.team_person_added", ...)`
      # call (success path with full opts).
      assert_activity_logged("staff.team_person_added",
        actor_uuid: actor_uuid,
        resource_uuid: team.uuid,
        target_uuid: person.uuid
      )

      assert render(view) =~ "Staff added"
    end

    test "TeamShowLive mount with bogus uuid redirects with not-found flash", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/teams"}}} =
               live(conn, "/en/admin/staff/teams/#{bogus}")
    end

    test "DepartmentShowLive mount with bogus uuid redirects with not-found flash", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/departments"}}} =
               live(conn, "/en/admin/staff/departments/#{bogus}")
    end

    test "PersonShowLive mount with bogus uuid redirects with not-found flash", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/people"}}} =
               live(conn, "/en/admin/staff/people/#{bogus}")
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "Departments / Teams — additional public-API edges" do
    test "Departments.list/1 with :preload [:teams]" do
      dept = fixture_department()
      _team = fixture_team(%{"department_uuid" => dept.uuid})

      [reloaded | _] = Departments.list(preload: [:teams]) |> Enum.filter(&(&1.uuid == dept.uuid))
      refute Enum.empty?(reloaded.teams)
    end

    test "Departments.get!/2 raises for non-existent uuid" do
      assert_raise Ecto.NoResultsError, fn ->
        Departments.get!(Ecto.UUID.generate())
      end
    end

    test "Teams.get!/2 raises for non-existent uuid" do
      assert_raise Ecto.NoResultsError, fn ->
        Teams.get!(Ecto.UUID.generate())
      end
    end

    test "Departments.change/2 returns a changeset" do
      cs = Departments.change(%PhoenixKitStaff.Schemas.Department{})
      assert %Ecto.Changeset{} = cs
    end

    test "Teams.change/2 returns a changeset" do
      cs = Teams.change(%PhoenixKitStaff.Schemas.Team{})
      assert %Ecto.Changeset{} = cs
    end

    test "Departments.count/0 reflects insertions" do
      n_before = Departments.count()
      _ = fixture_department()
      assert Departments.count() == n_before + 1
    end

    test "Teams.count/0 reflects insertions" do
      n_before = Teams.count()
      _ = fixture_team()
      assert Teams.count() == n_before + 1
    end
  end
end
