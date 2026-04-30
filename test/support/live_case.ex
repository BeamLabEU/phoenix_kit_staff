defmodule PhoenixKitStaff.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitStaff.Web.DepartmentFormLiveTest do
        use PhoenixKitStaff.LiveCase

        test "renders", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/staff/departments/new")
          assert html =~ "New Department"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitStaff.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitStaff.ActivityLogAssertions
      # Reuse the fixture helpers defined on DataCase so LiveView tests
      # don't need their own duplicate copies.
      import PhoenixKitStaff.DataCase,
        only: [
          fixture_department: 0,
          fixture_department: 1,
          fixture_team: 0,
          fixture_team: 1,
          fixture_person: 0,
          fixture_person: 1,
          errors_on: 1
        ]

      import PhoenixKitStaff.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitStaff.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  Staff LVs read `socket.assigns[:phoenix_kit_current_user]` to thread
  the user UUID into activity logging. They don't call `Scope.admin?/1`
  themselves — the production `live_session :phoenix_kit_admin`
  on_mount hook gates that — but per workspace AGENTS.md `cached_roles`
  must be a list of role-name strings if `admin?/1` ever gets called,
  so we follow the convention.

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role-name strings; defaults to `["Owner"]`
    * `:permissions` — list of module-key strings; defaults to `["staff"]`
    * `:authenticated?` — defaults to `true`

  ## Example

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/staff/")
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, ["Owner"])
    permissions = Keyword.get(opts, :permissions, ["staff"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end

  # Fixture helpers (`fixture_department/1`, `fixture_team/1`,
  # `fixture_person/1`) live on `PhoenixKitStaff.DataCase` and are
  # imported into the `using` block above. Keep them out of this
  # module to prevent drift between DataCase and LiveCase fixtures.
end
