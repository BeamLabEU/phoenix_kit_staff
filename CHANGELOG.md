# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.5.0] - 2026-06-15

Structured skills taxonomy with per-skill dynamic proficiency levels,
soft-delete for people, a Comments tab on the person profile, and an
admin-UI quality sweep (kebab row menus + core empty-states). Merged as
PR #10.

**Requires `phoenix_kit ~> 1.7 and >= 1.7.132`** for the `metadata` JSONB
column (V131, soft-delete stash) and the `phoenix_kit_staff_skills` /
`phoenix_kit_staff_person_skills` tables (V135). Adds a hard dep on
`phoenix_kit_comments ~> 0.2` for the person Comments tab.

### Added
- **Structured skills.** A first-class, translatable `Skill` taxonomy
  (`phoenix_kit_staff_skills`, globally unique `lower(name)`) replacing
  the old free-text `Person.skills` (V135 migrates + drops it). Each
  skill defines its **own** proficiency levels — a `levels` JSONB array
  of translatable `%{"id", "name", "translations"}` maps with stable ids
  plus an `allow_multiple_levels` boolean. New context
  `PhoenixKitStaff.Skills` (skill CRUD + person↔skill assignment), new
  schemas `Skill` + `PersonSkill` (join carrying a `proficiency_levels`
  array of selected level ids), and thin `Staff` delegators.
- **Skills admin subtab** with `SkillsLive` / `SkillFormLive` /
  `SkillShowLive`. Assignment works from two directions: the skill show
  (skill → people, event-driven level toggle chips persisted
  immediately) and the person edit form (person → skills, staged
  multi-select reconciled to the DB on save).
- **Soft-delete (people).** `trash_person` / `restore_person` (sentinel
  `status = "trashed"`, prior status stashed in
  `metadata["trashed_from_status"]`), permanent `delete_person` (Trash
  view only), and set-based `bulk_trash` / `bulk_restore` /
  `bulk_delete`. `list_people/1` excludes trashed by default;
  `count_trashed/0` is separate. `PeopleLive` gains a "Trashed (N)"
  filter, core bulk-select, and a per-row kebab; `PersonShowLive` shows
  a trashed banner with Restore / Delete-permanently.
- **Comments tab** on `PersonShowLive` via the `phoenix_kit_comments`
  embed (`use PhoenixKitComments.Embed` for Leaf-event forwarding).
- New activity actions: `staff.person_trashed/restored`,
  `staff.people_bulk_trashed/restored/deleted`,
  `staff.skill_created/updated/deleted`,
  `staff.person_skill_added/removed/updated`.

### Changed
- **Admin-UI sweep.** Row actions across Departments / Teams / People /
  team-show / overview moved to the core `<.table_row_menu>` kebab; the
  seven hand-rolled empty-state blocks now use the core `<.empty_state>`
  component. `staff.person_deleted` now means the **permanent** delete.
- `Staff` context split: team-membership and org-tree logic extracted to
  `PhoenixKitStaff.Staff.Memberships` and `PhoenixKitStaff.Staff.Org`.
- `mix.exs`: `phoenix_kit` constraint widened to
  `~> 1.7 and >= 1.7.132`; added `phoenix_kit_comments ~> 0.2`; deps now
  resolve through the `pk_dep/3` `<APP>_PATH` cross-repo override helper.

## [0.4.0] - 2026-06-04

Internationalization release — the staff module now owns a Gettext
backend with Estonian + Russian translations, and the multilang
free-text overrides finally render in the UI.

### Added
- **`PhoenixKitStaff.Gettext` backend** for staff-specific (domain) UI
  strings, with full **Estonian (et)** and **Russian (ru)** catalogs in
  `priv/gettext` (146 msgids each, plurals included). Generic strings
  already translated workspace-wide stay routed to core's
  `PhoenixKitWeb.Gettext` (the hybrid-backend pattern). Admin `%Tab{}`
  labels carry `gettext_backend:` and stay extractable via
  `PhoenixKitStaff.__tab_label_strings__/0`.
- **`PhoenixKitStaff.L10n.current_content_lang/0`** — resolves the active
  content language (`Gettext.get_locale/1`) for read-path translation
  lookups, mirroring `phoenix_kit_projects`.

### Changed
- **Localized read paths.** The overview, list, and show LiveViews now
  render Department/Team names + descriptions and Person job titles, bios,
  skills, and notes through their `localized_*/2` helpers (primary-column
  fallback), so the `translations` JSONB overrides entered in the forms
  are actually displayed in the browsing locale. Previously these helpers
  had no callers and the overrides were write-only.

### Fixed
- **Hex packaging:** `priv` is now included in the package `files:` list,
  so published builds ship the `priv/gettext` catalogs. Without it the
  compiled Gettext backend had an empty catalog for Hex consumers and
  every staff string fell back to English.
- Dropped a dead `preload: [:teams]` in `DepartmentShowLive`.
- `mix.exs` now wires `.dialyzer_ignore.exs` explicitly via
  `ignore_warnings:` (matching `phoenix_kit_projects`).

## [0.3.0] - 2026-05-29

Feature release — multilingual free-text fields, a single full-name
column, and a soft dependency on `phoenix_kit_locations` for the work
location. All changes are additive and backward-compatible with the
documented public API (`Staff.list_people/1`,
`Staff.get_person_by_user_uuid/2`, `Teams.list/1`, `Departments.list/1`).

**Requires `phoenix_kit ~> 1.7.125`** for the V122 migration that ships
the `translations` JSONB columns and `phoenix_kit_staff_people.name`.

### Added
- **Multilang translations** on Department, Team, and Person. Each
  schema carries a `translations` JSONB column for non-primary-language
  overrides on a subset of free-text fields (Department/Team: `name`,
  `description`; Person: `job_title`, `bio`, `skills`, `notes`).
  `<Schema>.localized_<field>/2` read helpers apply primary-fallback
  semantics; forms use the shared `<.multilang_tabs>` /
  `<.multilang_fields_wrapper>` / `<.translatable_field>` components.
- **`Person.name`** — a single nullable `VARCHAR(255)` full display
  name, consistent with `Department.name` / `Team.name`. Owned by the
  staff profile so placeholder users stay anonymous until claimed.
- **`Person.display_name/1`** — canonical people label (name → linked
  user's first/last → email → "Unnamed"), used across the people list,
  org overview, birthdays, person show, and team show.
- **`PhoenixKitStaff.L10n.validate_translations/1` and
  `localized_field/3`** — shared translation read/validate helpers
  (the schemas now delegate instead of carrying private copies).
- `Staff.list_people/1` search now matches `name` in addition to the
  linked user's email.

### Changed
- **`Person.work_location` is now a soft dependency on
  `phoenix_kit_locations`.** The form renders a Location picker sourced
  via a runtime guard (`Code.ensure_loaded?/1` + `function_exported?/3`
  + variable-module dispatch, so the optional dep is never referenced at
  compile time) and hides the field entirely when the locations module
  isn't installed or is disabled. The column stays `VARCHAR` (UUID
  stored as a string) to avoid a type-changing migration.
- `Person.skills` is now a free-form textarea (was single-line).
- **Style sweep** across all 10 admin LiveViews: full-width
  (`w-full px-4 py-N`) layout with `<.admin_page_header>` + `<:actions>`,
  forms capped at `max-w-3xl mx-auto`; fixed an invisible
  hover-badge bug on the Overview page on light themes.
- Tightened the `phoenix_kit` constraint to `~> 1.7.125` (was `~> 1.7`)
  so installs can't resolve a pre-V122 core; refreshed the dependency
  lock (`phoenix_kit` 1.7.125, `phoenix_live_view` 1.1.31,
  `ecto_sql` 3.14.0).

### Fixed
- Overview / Person show now display the person's name rather than
  always falling back to the linked user's email.

## [0.2.1] - 2026-05-12

Maintenance release — dep bumps, migration-shim cleanup, test repair,
and a documented heads-up for the upcoming `Person.work_schedule`
JSONB column. No public-API changes.

### Changed
- Bumped `phoenix_kit` to `~> 1.7.108` (from `1.7.106`); refreshed
  transitive deps (`postgrex` 0.22.2, `finch` 0.22.0, `ex_ast` 0.11.2,
  `swoosh` 1.25.2, `telemetry` 1.4.2, plus new transitives
  `tessera`/`fresco`).
- Test infra: `test/test_helper.exs` and `config/test.exs` now lean on
  `PhoenixKit.Migration.ensure_current/2` directly — no module-owned
  DDL or hybrid migration shim.

### Removed
- `priv/repo/migrations/20260427000000_setup_phoenix_kit.exs` — the
  hybrid migration shim is gone. Test setup applies core's versioned
  migrations on every boot.

### Fixed
- `PersonFormLive` audit-row tests realigned for LiveView 1.1.29.

### Docs
- `AGENTS.md`: documented the planned `Person.work_schedule` JSONB
  column (shape, canonical "non-working day" representation, default
  empty map) as a heads-up for the cross-module `phoenix_kit_projects`
  follow-up. No schema change in this release.

## [0.2.0] - 2026-04-30

Quality sweep + re-validation pipeline (PRs #2 and #3) plus the
post-merge follow-up: form-Save audit rows, Errors fallback warning,
Helpers merge-precedence fix.

### Added
- `PhoenixKitStaff.Errors` — atom → translated-string dispatcher.
  Context functions now return `{:error, atom}`; LiveViews call
  `Errors.message/1` at the presentation boundary. Unknown-atom
  fallback emits a `Logger.warning` so drift is loud in dev/staging.
- `PhoenixKitStaff.Web.Helpers` — `log_operation_error/3` writes a
  failure-side activity row with `db_pending: true` and PII-safe
  reason metadata. Resolves the tension between the module's
  documented success-only `Activity` invariant at the call site and
  the post-Apr pipeline's both-branch audit-row requirement. Wired
  into all 5 destructive listing actions plus all 6 form Save error
  branches (department / team / person × create + edit).
- `@type t` on every Ecto schema; 41 new `@spec`s across the public
  context and helper modules.
- Test infrastructure under `test/support/`: `Test.Endpoint`,
  `Test.Router`, `Test.Layouts`, `DataCase`, `LiveCase`, `Hooks`,
  `ActivityLogAssertions`. `lazy_html` test-only dep for
  `Phoenix.LiveViewTest` HTML parsing.
- `mix test.setup` / `mix test.reset` aliases for local DB bootstrap.

### Changed
- **BREAKING (return-shape):** `Staff.rename_placeholder_email/2`
  now returns `{:error, atom}` (`:blank_email`,
  `:placeholder_already_claimed`, `:email_already_taken`) instead of
  `{:error, binary_message}`. Callers must route through
  `PhoenixKitStaff.Errors.message/1` at the presentation boundary.
- `Helpers.log_operation_error/3` metadata-merge precedence: caller-
  supplied metadata is now merged UNDER the helper-owned keys
  (`db_pending` / `error_kind` / `error_keys` / `error_atom`) so
  audit-feed readers can rely on those keys being authoritative.
  `:resource_uuid` opt is now optional (failed CREATE submissions
  have no uuid yet).
- `PhoenixKitStaff.Activity.log/2` rescue widened to canonical
  post-Apr shape: explicit `Postgrex.Error -> :ok` and
  `DBConnection.OwnershipError -> :ok` ahead of the generic
  `Logger.warning` branch, plus `catch :exit, _ -> :ok`.
- `PhoenixKitStaff.enabled?/0` adds `catch :exit, _ -> false` for
  sandbox-shutdown safety.
- `handle_info/2` catch-all in all 7 admin LVs promoted from silent
  `{:noreply, socket}` to `Logger.debug(...)`.
- `Staff.next_birthday_and_days/2` extracted shared
  `anniversary_in_year/2` helper that mirrors Postgres `INTERVAL '1
  year'` arithmetic.
- `Staff.org_tree/0` collapses `MapSet` build via `MapSet.new/2`.

### Fixed
- **Schema constraint name mismatch in `Schemas.Person.changeset/2`**
  (HIGH). The DB index is `phoenix_kit_staff_people_user_index`,
  but the changeset registered the Ecto-default
  `phoenix_kit_staff_people_user_uuid_index`, so duplicate
  `user_uuid` inserts raised `Ecto.ConstraintError` instead of
  returning `{:error, %Ecto.Changeset{}}`. Changeset now passes
  `name: :phoenix_kit_staff_people_user_index` explicitly.
- **`PersonShowLive.handle_info/2` had no catch-all** (MEDIUM). Any
  non-`{:staff, ...}` message reaching the LV's mailbox would have
  raised `FunctionClauseError`. Catch-all clause added.
- **Subscribe-after-fetch race on the 3 show pages** (LOW).
  `department_show_live` / `team_show_live` / `person_show_live`
  now subscribe BEFORE the DB read so a broadcast in the gap
  doesn't get silently dropped.
- **Leap-day display drift in `next_birthday_and_days/2`** (LOW).
  Wrap-to-next-year branch was unconditionally clamping Feb 29 →
  Feb 28 even when the target year was a leap year. Display now
  matches the Postgres SQL window filter exactly.
- **`Schemas.Team.changeset/2`** changes `unique_constraint` from
  `[:department_uuid, :name]` (composite list — error attached to
  the first field) to `unique_constraint(:name, name: ...)` so
  inline form errors render below the field the user actually edits.

### Performance
- `Staff.org_tree/0`: `MapSet.new(list, mapper)` skips an
  intermediate list allocation.

### Tests
- 49 → 302 tests, 0 failures, 5/5 stable.
- `mix test --cover`: 62.64% → **95.07%** line coverage.
- New test files cover: per-atom `Errors.message/1` pins, helpers
  unit tests with PII-safety assertions, error-branch logging,
  per-LV `handle_info` catch-all `Logger.debug` pins,
  subscribe-before-fetch source-pairing meta-test, edge-case
  Unicode/SQL-metacharacter inputs, all listing LVs, all form LVs
  with both happy-path AND failure-side audit-row pins.

### Internal
- `mix.exs` `test_coverage [ignore_modules]` filter so
  `mix test --cover` reports production-only coverage.
- `test_helper.exs` rescues `ErlangError` from `System.cmd("psql",
  ...)` so `mix test --exclude integration` works in environments
  without `psql` on PATH.

## [0.1.0] - 2026-04-20

Initial release.

### Added
- `Departments` context: list/create/update/delete with PubSub broadcasts.
- `Teams` context: list/create/update/delete with department scoping and
  PubSub broadcasts.
- `Staff` context: people CRUD (`Person` schema), team membership
  management, `upcoming_birthdays/1`, `org_tree/0`, and placeholder-user
  flow with transactional rollback.
- Activity logging via safe wrapper pattern, called at the LiveView layer.
- PubSub topic scoping for departments, teams, and people.
- Integration test suite (auto-excluded when `phoenix_kit_staff_test` DB
  is unavailable), including coverage of `upcoming_birthdays/1` (window
  boundaries, today / leap-day / wrap-around DOBs, inactive / nil-DOB
  exclusion, sort order) and `org_tree/0` (team-grouped, dept-only, and
  fully-unassigned buckets).
- `AGENTS.md` with project overview, conventions, testing, and PR policy.

### Performance
- `Staff.upcoming_birthdays/1` filters the day window in Postgres via
  interval arithmetic; only rows inside the window come back.
- `Staff.org_tree/0` loads `TeamMembership` once and derives both the
  team-grouped and unassigned shapes in memory.
