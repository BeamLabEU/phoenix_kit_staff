# Test helper for PhoenixKitStaff.
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests (tagged `:integration` via PhoenixKitStaff.DataCase)
#          require PostgreSQL — automatically excluded when the database
#          is unavailable.
#
# First-time setup:
#
#   mix test.setup          # or: createdb phoenix_kit_staff_test
#
# After that, `mix test` boots the repo, runs core's versioned migrations via
# `PhoenixKit.Migration.ensure_current/2` (later versions apply on every boot),
# replays the comments chain and this module's own chain, which is what builds
# the staff tables on core 3.x, and lets the Ecto sandbox handle isolation.

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

# One classified connection attempt, with the repo's OWN credentials and
# transport, before anything starts the pool. A `psql -lqt` listing asked the
# wrong question here: it ran as the shell's user over a unix socket, so it said
# nothing about whether the CONFIGURED role could reach the database over TCP.
# When it could not, the answer arrived minutes later as a pool checkout timeout
# that reads like a flaky test.
repo_available =
  with :ok <-
         PhoenixKit.TestSupport.PostgresPreflight.check(
           Application.get_env(:phoenix_kit_staff, TestRepo, [])
         ),
       {:ok, _} <- TestRepo.start_link() do
    true
  else
    {:error, _reason, message} ->
      IO.puts(:stderr, "\n" <> message)

      IO.puts("""

        Cannot reach test database "#{db_name}" — integration tests excluded.
        The reason is printed above. Once fixed, run: mix test.setup
      """)

      false

    {:error, reason} ->
      IO.puts("""

        Could not start the test repo — integration tests excluded.
        Run: createdb #{db_name} && mix test.setup
        Error: #{inspect(reason)}
      """)

      false
  end

# Past this point the database is there, so a failure building the schema is a
# real one and must stop the run. Rescuing it into "integration tests excluded"
# turned a broken migration, or a database behind core's floor, into a green
# `mix test` with most of the suite silently gone. A test database behind the
# floor needs `mix test.reset`; core's error says so.
if repo_available do
  # Build the schema directly from core's versioned migrations — same call the
  # host app makes in production. `ensure_current/2` re-applies any newly
  # shipped Vxxx migrations on every boot.
  PhoenixKit.Migration.ensure_current(TestRepo, log: false)

  # Comments' chain: the person page embeds a comment thread, and
  # `phoenix_kit_comments` belongs to that module (core 3.0 creates none).
  Enum.each(PhoenixKitComments.Migrations.up_statements("public"), &TestRepo.query!/1)

  # Then this module's own chain, as `mix phoenix_kit.update` runs it. `up/1`
  # needs an `Ecto.Migration` run; the SQL is data, so replay it.
  if PhoenixKitStaff.Migrations.migrated_version_runtime() <
       PhoenixKitStaff.Migrations.current_version() do
    Enum.each(PhoenixKitStaff.Migrations.up_statements("public"), &TestRepo.query!/1)
  end

  Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
end

Application.put_env(:phoenix_kit_staff, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the context layer.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

# `Staff.register_placeholder/1` flows through `PhoenixKit.Users.Auth.register_user/2`,
# which calls the Hammer-backed rate limiter. Without this its ETS table is
# absent and every integration test that creates a person fails at registration.
# Mirrors core's `phoenix_kit/test/test_helper.exs:69`.
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# `Scope.can?/2` honours a sub-permission (`staff.view_personal`) only while
# its module is registered and enabled, and granting one validates the key
# against the registry's declared sub-permissions.
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])

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

# `migrations_build_alone_test.exs` uses core's
# `PhoenixKit.TestSupport.ModuleChainCheck`, which the first core release after
# 2.64.1 ships; against an older core in `deps/` it is excluded.
chain_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.ModuleChainCheck),
    do: [],
    else: [:requires_module_chain_check]

exclude = if repo_available, do: chain_check, else: [:integration | chain_check]
ExUnit.start(exclude: exclude)

# The manifest test builds the module's tables with `ModuleChainCheck.build_alone/4`
# and hands the manifest to repair (`PhoenixKit.Module.expected_schema/0`); both
# arrive in the first core release after 2.64.1.
unless Code.ensure_loaded?(PhoenixKit.TestSupport.ModuleChainCheck) and
         function_exported?(PhoenixKit.TestSupport.ModuleChainCheck, :build_alone, 4) do
  ExUnit.configure(exclude: [:requires_core_expected_schema | ExUnit.configuration()[:exclude]])
end
