# AGENTS.md

Guidance for AI agents working on the `phoenix_kit_staff` plugin module.

## Project overview

A PhoenixKit plugin module that manages staff. Implements the `PhoenixKit.Module` behaviour for auto-discovery. Registers one admin tab (`Staff`) with subtabs:

- **Overview** — org tree (departments → teams → people), upcoming birthdays, quick actions
- **Departments** — flat list of departments
- **Teams** — teams across all departments
- **Staff** — people on staff (each linked 1:1 to a `PhoenixKit.Users.Auth.User`)

## Common commands

Run from the workspace app directory (`/www/app`), not from inside this plugin subdir — the plugin's deps live in the app's `_build`. Exception: `mix format` works anywhere.

```bash
# From /www/app:
mix compile                 # Compile the whole workspace including this plugin
mix format                  # Format (uses Phoenix LiveView import rules)
sudo supervisorctl restart elixir  # Restart the dev server after edits
```

## Dependencies

- `phoenix_kit` (path dep) — Module behaviour, Settings, RepoHelper, Users.Auth, Activity
- `phoenix_live_view` — admin pages
- `ecto_sql` — schemas, changesets

## Architecture

### Concepts

- **Department** — a top-level org unit
- **Team** — belongs to exactly one Department
- **Person** — staff profile, always linked to a `PhoenixKit.Users.Auth.User`. Can be on many Teams via `TeamMembership`. Has an optional `primary_department_uuid` independent of team memberships.
- **TeamMembership** — join row between Team and Person

### Schemas

- `PhoenixKitStaff.Schemas.Department` — `phoenix_kit_staff_departments`
- `PhoenixKitStaff.Schemas.Team` — `phoenix_kit_staff_teams`
- `PhoenixKitStaff.Schemas.Person` — `phoenix_kit_staff_people`
- `PhoenixKitStaff.Schemas.TeamMembership` — `phoenix_kit_staff_team_memberships`

All use `@primary_key {:uuid, UUIDv7}`, `timestamps(type: :utc_datetime)`, `@foreign_key_type UUIDv7`.

### Contexts

- `PhoenixKitStaff.Departments` — CRUD
- `PhoenixKitStaff.Teams` — CRUD
- `PhoenixKitStaff.Staff` — people CRUD (`list_people`, `get_person`, `create_person`, `update_person`, `delete_person`, `change_person`), team memberships, org tree, upcoming birthdays, and placeholder-user helpers (`find_or_create_user_by_email`, `create_person_with_user`, `rename_placeholder_email`)

### LiveViews

Under `PhoenixKitStaff.Web.*`:
- `OverviewLive` — org tree + birthdays
- `DepartmentsLive`, `DepartmentFormLive`, `DepartmentShowLive`
- `TeamsLive`, `TeamFormLive`, `TeamShowLive`
- `PeopleLive`, `PersonFormLive`, `PersonShowLive`

### URL paths

All under `/admin/staff/*`: `departments`, `teams`, `people`, plus `.../new`, `.../:id`, `.../:id/edit` for each. Use `PhoenixKitStaff.Paths` — never hardcode.

## Database

**Migrations live in `phoenix_kit` core** (versioned system). Current migration: `V100` creates all four staff tables. When changing the schema, add the next `VNN` migration in `/www/phoenix_kit/lib/phoenix_kit/migrations/postgres/`.

## Placeholder user flow

The staff form accepts any email. If the user doesn't exist, `Staff.find_or_create_user_by_email/1` creates a placeholder (unconfirmed, random password, `custom_fields.source = "staff_placeholder"`). When the person later registers or signs in via OAuth with the same email, PhoenixKit's built-in email lookup auto-links them.

`Staff.create_person_with_user/2` is a transaction-like wrapper that rolls back a freshly-created placeholder if the staff profile insert fails.

The form allows renaming a placeholder's email until it's claimed (via `Staff.rename_placeholder_email/2`, which refuses if the user is confirmed or isn't tagged as a placeholder).

## Activity logging

Every mutation logs via the `PhoenixKitStaff.Activity` wrapper — **never call `PhoenixKit.Activity.log/1` directly from this plugin**. The wrapper centralizes the `Code.ensure_loaded?(PhoenixKit.Activity)` guard, rescue, and default metadata (module key, actor_role) so every call site stays consistent. Action strings follow `"staff.<resource>_<verb>"`:

- `staff.person_created/updated/deleted`
- `staff.department_created/updated/deleted`
- `staff.team_created/updated/deleted`
- `staff.team_person_added/removed`

**Where to log:** activity logging happens at the **LiveView layer**, not inside context functions. The LiveView is where `actor_uuid` is accessible (via `socket.assigns[:phoenix_kit_current_user]`) and where user intent is unambiguous ("admin clicked Save" vs. "internal function called during a cascade"). Context functions like `Staff.create_person/2` stay pure — they perform the mutation and return `{:ok, record} | {:error, changeset}`, and the calling LiveView logs on success.

All calls through the wrapper are guarded with `Code.ensure_loaded?(PhoenixKit.Activity)` and rescued — logging failures never crash the caller.

## Permissions

Uses `permission: "staff"` from the PhoenixKit role/permission matrix. Tabs are gated on this; individual LiveView events trust the mount-level check.

## Settings keys

- `staff_enabled` — boolean, read by `PhoenixKitStaff.enabled?/0`, toggled via **Admin > Modules**. `enabled?` rescues all errors and returns `false` so missing settings tables don't crash module discovery.

## File layout

```
lib/phoenix_kit_staff.ex                     # Main module (PhoenixKit.Module behaviour)
lib/phoenix_kit_staff/
├── activity.ex                              # Activity logging wrapper
├── departments.ex                           # Context: departments CRUD
├── l10n.ex                                  # Date/time localization helpers
├── paths.ex                                 # Path helpers (/admin/staff/*)
├── pub_sub.ex                               # Topics + broadcast helpers
├── staff.ex                                 # Context: people + memberships + org_tree
├── teams.ex                                 # Context: teams CRUD
├── schemas/
│   ├── department.ex
│   ├── person.ex                            # Employment metadata + emergency contacts
│   ├── team.ex
│   └── team_membership.ex
└── web/
    ├── department_form_live.ex
    ├── department_show_live.ex
    ├── departments_live.ex
    ├── overview_live.ex                     # Org tree + upcoming birthdays
    ├── people_live.ex
    ├── person_form_live.ex                  # Placeholder-user flow lives here
    ├── person_show_live.ex
    ├── team_form_live.ex
    ├── team_show_live.ex
    └── teams_live.ex
```

## Versioning & Releases

Versioning follows [SemVer](https://semver.org/). The version appears in two places that must stay in sync:

1. `mix.exs` — the `@version` module attribute
2. `lib/phoenix_kit_staff.ex` — `def version, do: "x.y.z"` (returned by the `PhoenixKit.Module` callback)

Release checklist:

1. Bump both versions; add a `CHANGELOG.md` entry
2. Run `mix precommit` — must exit clean
3. Commit ("Bump version to x.y.z") and push
4. Tag with the bare version: `git tag x.y.z && git push origin x.y.z`
5. Create a GitHub release via `gh release create`

## Cross-module consumption

The `phoenix_kit_projects` module depends on this plugin — `Assignment` and `Task` schemas reference `PhoenixKitStaff.Schemas.{Team, Department, Person}` directly. Keep the following public API stable:

- `PhoenixKitStaff.Staff.list_people/1`
- `PhoenixKitStaff.Staff.get_person_by_user_uuid/2`
- `PhoenixKitStaff.Teams.list/1`
- `PhoenixKitStaff.Departments.list/1`

## Conventions

- **Paths**: all through `PhoenixKitStaff.Paths.*` (which uses `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling)
- **Activity**: always via `PhoenixKitStaff.Activity` wrapper, always at the LiveView layer
- **Email validation**: centralized in `PhoenixKitStaff.Staff.email_regex/0` + `valid_email?/1`
- **Tab IDs**: prefix with `:admin_staff_*`
- **LiveView assigns**: `@phoenix_kit_current_scope`, `@phoenix_kit_current_user`, `@current_locale`, `@url_path` are injected by PhoenixKit's on_mount hooks
- **LiveView layout**: `use PhoenixKitWeb, :live_view` (in `phoenix_kit_web.ex`) injects `layout: PhoenixKit.LayoutConfig.get_layout()` automatically. No need to wrap templates in `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` — that wrapper is for LiveViews served outside the admin live_session
- **Gettext**: all user-visible strings wrapped via `use Gettext, backend: PhoenixKitWeb.Gettext` then `gettext(...)` — shares the parent app's backend, no separate domain

## Pre-commit commands

Always run before git commit (mirrors the root `phoenix_kit` workflow):

```bash
# 1. Run the full pre-commit chain
mix precommit               # compile + format + credo --strict + dialyzer

# 2. Fix any problems surfaced above (warnings-as-errors in compile, format diffs, credo issues, dialyzer specs)

# 3. Review changes
git diff
git status

# 4. Commit
```

Step order matters: `compile` first (warnings-as-errors catches the loud stuff), then `format`, then `credo --strict`, then `dialyzer`. Run from `/www/app` to resolve deps correctly; `mix format` is the only one that works from inside the plugin subdir.

## Testing

Two levels:

- **Unit tests** in `test/phoenix_kit_staff/` — schemas, changesets, pure helpers. Always run.
- **Integration tests** in `test/phoenix_kit_staff/integration/` — hit a real PostgreSQL database via the Ecto sandbox. Use `PhoenixKitStaff.DataCase`.

Test infrastructure:

- `test/support/test_repo.ex` — `PhoenixKitStaff.Test.Repo` (loaded explicitly in `test_helper.exs`)
- `test/support/data_case.ex` — `PhoenixKitStaff.DataCase`, tags tests `:integration`, sets up the SQL Sandbox
- `test/test_helper.exs` — runs `PhoenixKit.Migrations.up()` once at boot (creates `phoenix_kit_users`, `phoenix_kit_settings`, and all V100 staff tables), then puts the sandbox in `:manual` mode
- `config/test.exs` — repo config (env-var driven via `PGUSER` / `PGPASSWORD` / `PGHOST`)

Commands:

```bash
# First time only:
createdb phoenix_kit_staff_test

# All runs (unit + integration if DB is reachable):
mix test

# Unit tests only (DB not required):
mix test --exclude integration
```

Integration tests are auto-excluded if the DB isn't reachable (the helper prints a note and `ExUnit.start(exclude: [:integration])`). `mix test` therefore never hard-fails on a missing DB.

## CI expectations

GitHub Actions run on push and PRs: formatting check, `credo --strict`, `dialyzer`, compile with warnings-as-errors, and `mix test`. A failure in any of these blocks merge.

## Pull requests

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` with `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`). See the root `phoenix_kit/AGENTS.md` section on PR reviews for the authoritative directory layout.

Severity levels for review findings:

- `BUG - CRITICAL` — Will cause crashes, data loss, or security issues
- `BUG - HIGH` — Incorrect behavior that affects users
- `BUG - MEDIUM` — Edge cases, minor incorrect behavior
- `IMPROVEMENT - HIGH` — Significant code quality or performance issue
- `IMPROVEMENT - MEDIUM` — Better patterns or maintainability
- `NITPICK` — Style, naming, minor suggestions

## Commit message rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.
