import Config

# Integration tests run against a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_staff_test
config :phoenix_kit_staff, ecto_repos: [PhoenixKitStaff.Test.Repo]

config :phoenix_kit_staff, PhoenixKitStaff.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_staff_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wire repo for PhoenixKit.RepoHelper — without this, context-layer DB calls crash.
config :phoenix_kit, repo: PhoenixKitStaff.Test.Repo

# Test Endpoint for LiveView tests. `phoenix_kit_staff` has no endpoint
# of its own in production — the host app provides one — so this
# endpoint only exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_staff, PhoenixKitStaff.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "staff-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitStaff.Test.Layouts]]

config :phoenix, :json_library, Jason

config :logger, level: :warning
