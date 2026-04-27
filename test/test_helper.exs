# Test helper for PhoenixKitStaff.
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests (tagged `:integration` via PhoenixKitStaff.DataCase)
#          require PostgreSQL — automatically excluded when the database
#          is unavailable.
#
# First-time setup:
#
#   createdb phoenix_kit_staff_test
#   mix test.setup
#
# After that, `mix test` boots the repo and lets the Ecto sandbox handle
# isolation. The schema is built by
# `test/support/postgres/migrations/<timestamp>_setup_phoenix_kit.exs`,
# which calls `PhoenixKit.Migrations.up()` for prereq tables and inlines
# the V100 staff DDL (since current Hex `phoenix_kit` predates V100).

# Elixir 1.19's `mix test` no longer auto-loads modules from
# `:elixirc_paths` test directories at test-helper time — only files
# matching `:test_load_filters` get loaded by the test runner. Explicit
# `Code.require_file/2` is needed before `test_helper.exs` references
# the support modules.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

alias PhoenixKitStaff.Test.Repo, as: TestRepo

db_name =
  Application.get_env(:phoenix_kit_staff, TestRepo, [])[:database] ||
    "phoenix_kit_staff_test"

db_check =
  case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
    {output, 0} ->
      exists =
        output
        |> String.split("\n")
        |> Enum.any?(fn line ->
          line |> String.split("|") |> List.first("") |> String.trim() == db_name
        end)

      if exists, do: :exists, else: :not_found

    _ ->
      :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""

      Test database "#{db_name}" not found — integration tests excluded.
      Run: createdb #{db_name} && mix test.setup
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()
      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name} && mix test.setup
          Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name} && mix test.setup
          Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_staff, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the context layer.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

# `Staff.register_placeholder/1` flows through `PhoenixKit.Users.Auth.register_user/2`,
# which calls the Hammer-backed rate limiter. Without this its ETS table is
# absent and every integration test that creates a person fails at registration.
# Mirrors core's `phoenix_kit/test/test_helper.exs:69`.
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Force PhoenixKit's URL prefix cache to "/" for tests so `Paths.index()`
# etc. produce paths the test router can match. Admin paths always get
# the default locale ("en") prefix, so our router scope is `/en/admin/staff`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive our LiveViews
# via `live/2` with real URLs. Runs with `server: false`, so no port is
# opened. Only starts when the test DB is available — without DB,
# LiveView tests are excluded anyway.
if repo_available do
  {:ok, _} = PhoenixKitStaff.Test.Endpoint.start_link()
end

exclude = if repo_available, do: [], else: [:integration]
ExUnit.start(exclude: exclude)
