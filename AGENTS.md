# AGENTS.md

Guidance for AI agents working on the `phoenix_kit_staff` plugin module.

## Project overview

A PhoenixKit plugin module that manages staff. Implements the `PhoenixKit.Module` behaviour for auto-discovery. Registers one admin tab (`Staff`) with subtabs: **Overview** (org tree, upcoming birthdays), **Departments**, **Teams**, **Staff** (people, each linked 1:1 to a `PhoenixKit.Users.Auth.User`), **Skills** (skill taxonomy + proficiency levels).

## What this module does NOT have (by design)

Org-structure backbone only. Deliberately omitted — build these as sibling modules consuming Staff's stable public API instead (`phoenix_kit_projects` already follows this pattern):

- No leave/PTO tracking, no performance reviews, no payroll/compensation/contract data. (Employment **history** spans *are* tracked — org/role history, not compensation.)
- No org-chart visualization beyond the Overview's plain-HTML nested list.
- No bulk import — single-record forms only; use the context API (`Staff.create_person/2`, etc.) for scripted imports.
- No public-facing pages (admin-only), no external HRIS integrations.
- No audit history beyond the `PhoenixKit.Activity` feed.

## Common commands

Run from the workspace app directory (`/www/app`), not from inside this plugin subdir — the plugin's deps live in the app's `_build`. Exception: `mix format` works anywhere.

```bash
mix compile                 # warnings-as-errors
mix format
mix credo --strict
mix dialyzer
mix precommit               # compile + format + credo --strict + dialyzer — run before every commit
mix quality / mix quality.ci
sudo supervisorctl restart elixir  # restart the dev server after edits
```

## Dependencies

- `phoenix_kit` — Module behaviour, Settings, RepoHelper, Users.Auth, Activity
- `phoenix_kit_comments` (`~> 0.2`) — **hard, compile-time** dep (person profile Comments tab)
- `phoenix_live_view`, `ecto_sql`

## Local cross-repo development

`phoenix_kit*` deps resolve from Hex by default. Export `<APP>_PATH` (dep's app name upper-cased + `_PATH`: `:phoenix_kit` → `PHOENIX_KIT_PATH`) to swap the Hex pin for a `path:` + `override: true` dep at resolve time; set several to override multiple. Unset = the published pin. Implemented via `pk_dep/3` in `mix.exs` — **never** hand-edit a `phoenix_kit*` dep into a `path:` tuple (a committed path dep ships a broken package).

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

## Architecture

### Concepts

- **Department** — top-level org unit
- **Team** — belongs to exactly one Department
- **Person** — staff profile, always linked 1:1 to a User; many Teams via **TeamMembership**; optional `primary_department_uuid` independent of memberships
- **Skill** — flat, translatable; assigned to people many-to-many via **PersonSkill** (carries selected level-option ids)
- **Employment** — per-person history span (see Employment history)

### Schemas

`PhoenixKitStaff.Schemas.{Department, Team, Person, TeamMembership, Skill, PersonSkill, Employment}` → tables `phoenix_kit_staff_{departments, teams, people, team_memberships, skills, person_skills, employments}`. All use `@primary_key {:uuid, UUIDv7}`, `timestamps(type: :utc_datetime)`, `@foreign_key_type UUIDv7`.

### Contexts

- `Departments`, `Teams` — CRUD
- `Skills` — skill CRUD + person↔skill assignment (**sole write path** for assignments)
- `Employments` — span CRUD + one-open-span invariant + `sync_current/1`
- `Staff` — people CRUD, memberships, `org_tree/0`, `upcoming_birthdays/1`, placeholder-user helpers, thin delegators to `Skills`

### LiveViews

Under `PhoenixKitStaff.Web.*`: `OverviewLive`, plus `Departments/Teams/People/Skills Live` + `…FormLive` + `…ShowLive` trios. `PersonShowLive` hosts tab components (`PersonEmploymentComponent`, `PersonMediaComponent`, `PersonEventsComponent`, comments).

### URL paths

All under `/admin/staff/*` (`departments`, `teams`, `people`, `skills`, each with `…/new`, `…/:id`, `…/:id/edit`). Always via `PhoenixKitStaff.Paths` — never hardcode.

## Database

**Migrations live in `phoenix_kit` core** (versioned system) — never module-owned DDL. Staff tables ship in `V100`; later cross-cut migrations:

- `V122` — `translations JSONB` on departments/teams/people + single `name VARCHAR` on people
- `V131` — `metadata JSONB` on people (required by soft-delete's `trashed_from_status` stash)
- `V135` — skills + person_skills tables; migrates and **drops** the old free-text `people.skills` (lossy: per-locale `translations["skills"]` overrides are stripped)
- `V136` — `phoenix_kit_staff_employments` + backfill; keeps the mirrored `people` employment columns

To change the schema, add the next `VNN` migration in `/www/phoenix_kit/lib/phoenix_kit/migrations/postgres/`. A recent migration may need a core release newer than the Hex lock — use `PHOENIX_KIT_PATH` locally until it lands.

## Multilang translations

Department, Team, Person, Skill carry a `translations` JSONB column holding **non-primary-language overrides only** (`%{"es-ES" => %{"name" => "…"}}`); primary values stay in their dedicated columns.

- Translatable fields: Department/Team/Skill `name` + `description`; Person `job_title`, `bio`, `notes` (NOT `name`, NOT `work_location`).
- Reads: `<Schema>.localized_<field>/2` helpers with primary-fallback. Changesets validate shape via `L10n.valid_translations_shape?/1`.
- Forms: `<.multilang_tabs>` + `<.multilang_fields_wrapper>` + `<.translatable_field>` from core `PhoenixKitWeb.Components.MultilangForm`. The wrapper **re-mounts on language switch** — render non-translatable fields as siblings outside it or they lose state.

## Skills

First-class translatable many-to-many taxonomy (replaced free-text `Person.skills` in V135), managed via the Skills admin subtab.

- **`Skill.levels` JSONB** = ordered list of named **selectors**: `%{"id", "name", "translations", "allow_multiple", "options" => [%{"id", "name", "translations"}]}`. Selector/option names are user data in `translations`, not gettext. `Skill.level_groups/1` wraps the legacy V135 flat-list shape (+ legacy `allow_multiple_levels` column) into one default selector on read — per-selector `allow_multiple` is authoritative; no migration was needed. Other helpers: `group_options/1`, `all_option_ids/1`, `find_option/2`, `localized_group_name/3`, `localized_option_name/3`, `option_choices/3`, `selected_by_group/2`, `toggle_option/3`, `gen_level_id/0`; `normalize_levels/1` strictly validates the nested shape.
- **`PersonSkill.proficiency_levels` JSONB** = selected **option** ids across all of the skill's selectors (option ids are unique within a skill; `[]` = nothing selected). The changeset only normalises; **semantic** validation (ids ⊆ options, ≤1 per single-select selector, canonical order) lives in `Skills`.
- **Assignment** in `Skills` (`assign_skill`, `unassign_skill`, `update_assignment_levels`, `validate_level_ids`, `prune_level_ids`, rosters) with thin `Staff` delegators. `Skills.update/2` reconciles existing assignments in one transaction (strips removed option ids; prunes a selector to ≤1 on multiple→single flip).
- **UI, two directions:** skill show — per-selector event-driven toggle chips, persisted immediately; person edit form — **staged** type-to-search multi-select written only on save (`PersonFormLive.sync_skills/2` reconciles after upsert; `phx-window-focus` re-queries the taxonomy). Person show renders assignments read-only.
- Skill delete cascades assignments (FK `ON DELETE CASCADE`); the UI surfaces the "removed from N people" count. No categories/grouping (deliberate v1 cut).

## Employment history

A person's employment is a **history of spans** (V136), surfaced as the **Employment tab** on person show — not fields on the person form. Each span records `employment_type`, translatable `job_title`, org placement (`primary_department_uuid` + `primary_team_uuid` **snapshot**), date range (`employment_end_date nil` = open/current), `work_location`, `notes`.

- **One open span per person** — partial unique index (`WHERE employment_end_date IS NULL`). `Employments` is the sole write path; `create/2` closes the prior open span at the new span's start.
- The open span drives a **denormalized mirror on Person** (`employment_type`, `job_title` + translations, dates, `primary_department_uuid`, `work_location`) written by `Employments.sync_current/1` in the same transaction — server-owned, **never cast from the person form**. The person edit form has no employment fields or department picker; only `status` + the team picker (which lists all teams).
- The span's `primary_team_uuid` is a history snapshot only — it does not change `TeamMembership`.
- UI: `PersonEmploymentComponent` (timeline + add/edit form, persists immediately, logs `staff.person_employment_*`); `:person_employment_changed` broadcast refreshes the host.
- v1 cuts: `job_title` edited in primary language only; per-span team is a snapshot, not membership management.

## Media attachments — Files & Images tabs

Backed by core `PhoenixKit.Modules.Storage` (folder-scoped convention — **no module-owned table, no migration**). Helper: `PhoenixKitStaff.Attachments`.

- **Folders:** deterministic root `staff-person-<uuid>` + nested `Images` subfolder. **Resolved by name on every read** (never cached on Person), created lazily on first upload; core's `[:name, :parent_uuid]` unique index makes find-or-create race-safe.
- **Component:** `PersonMediaComponent` (`kind: :files | :images`) opens core's `MediaSelectorModal` scoped to the folder. Both tabs gated on `PhoenixKit.Modules.Storage.enabled?()` (rescued) at the tab AND in mutation handlers; `valid_tabs/1` clamps deep-links.
- **Removal is non-destructive:** soft-trash a sole-owner file, unlink a shared one — never hard delete. Permanent person delete cascades the folder subtree via `Attachments.purge_person_media/1`; soft-trash keeps files.
- **Avatar:** single image pointer in `Person.metadata["avatar_uuid"]` (no column), via `Attachments.{avatar_uuid, avatar_file, avatar_url, set_avatar, clear_avatar}` — metadata writes merge, never clobber other keys. `PersonShowLive` hosts the picker and logs `staff.person_avatar_set/removed`.

## Events tab

`PersonEventsComponent` — **read-only, offset-paginated** feed of the person's `PhoenixKit.Activity` entries via `Activity.list(resource_type: "staff_person", resource_uuid: person.uuid, …)`. Labels/icons from `PhoenixKitStaff.ActivityLabels` (humanized fallback); badge colour from core `Activity.action_badge_color/1`. No live PubSub prepend.

## Person.name

Single nullable `name` VARCHAR(255) for the full display name (consistent with `Department.name`, `Team.name`). Lives on Person, not User: staff profiles have their own lifecycle, and placeholder users are anonymous until claimed. No first/middle/last split — per-cultural name parsing is out of scope.

## Work location — soft dep on phoenix_kit_locations

`Person.work_location` is a soft FK to a Location row (UUID stored as a VARCHAR string). The form's select is sourced from `PhoenixKitLocations.list_locations/0` and rendered only when the module is loaded and enabled (`Code.ensure_loaded?(PhoenixKitLocations) and PhoenixKitLocations.enabled?()`); person show falls back to the raw stored value otherwise.

## Placeholder user flow

The staff form accepts any email. `Staff.find_or_create_user_by_email/1` creates a placeholder (unconfirmed, random password, `custom_fields.source = "staff_placeholder"`); later registration/OAuth with the same email auto-links via core's email lookup. `Staff.create_person_with_user/2` rolls back a freshly-created placeholder if the profile insert fails. `Staff.rename_placeholder_email/2` allows renaming until claimed (refuses confirmed or non-placeholder users).

## Soft-delete (people)

Sentinel `status = "trashed"` on the existing status column — **never** a `deleted_at`. Mandatory because `phoenix_kit_projects` FKs target `Person.uuid` (`ON DELETE SET NULL`): a hard delete would silently NULL project assignments.

Context API (`Staff`):

- `trash_person/1` — stashes prior status in `metadata["trashed_from_status"]`; `{:error, :already_trashed}` if already trashed
- `restore_person/1` — restores stashed status (validated, else `"active"`); `{:error, :not_trashed}` otherwise
- `delete_person/1` — **permanent** hard delete (Trash view only); `{:error, :referenced_by_external}` on FK/NOT-NULL violation (defensive)
- `bulk_trash/1`, `bulk_restore/1`, `bulk_delete/1` — set-based
- `create_person/1` returns `{:error, {:trashed_person_exists, person}}` on a trashed 1:1 match — the form offers Restore

Scoping: `list_people/1` **excludes trashed by default** (`status: "trashed"` for the Trash view, `include_trashed: true` for all); `count_people/0` excludes trashed (`count_trashed/0` separate); `org_tree/0`, `people_not_on_team/1`, `upcoming_birthdays/1` exclude trashed; `eligible_users/1` still excludes trashed people's users (they flow through Restore, not re-create).

UI: `PeopleLive` "Trashed (N)" filter + per-row kebab (Restore / Delete-permanently in Trash view) + core bulk-select (permanent delete routes through `<.confirm_modal>`); `PersonShowLive` trashed banner + Restore / Delete-permanently.

## Comments (person profile)

`PersonShowLive` carries a **Comments** tab backed by `phoenix_kit_comments` — a **hard, compile-time** dep (`~> 0.2`), unlike the soft locations dep.

- `use PhoenixKitComments.Embed` installs the hook forwarding the composer's `{:leaf_changed, …}` into `CommentsComponent.forward_leaf_event/2` — without it "Post comment" silently no-ops. `{:comments_updated, _}` has an explicit no-op `handle_info/2`.
- Thread bound by `resource_type="staff_person"` + `resource_uuid={person.uuid}`.
- Runtime-gated on `PhoenixKitComments.enabled?()` (rescued); `valid_tabs/1` drops the tab when disabled (deep-links fall back to Overview).

## Activity logging

Every mutation logs via the `PhoenixKitStaff.Activity` wrapper — **never call `PhoenixKit.Activity.log/1` directly**. Logging happens at the **LiveView layer**, not in contexts: the LiveView owns `actor_uuid` (`socket.assigns[:phoenix_kit_current_user]`) and user intent; context functions stay pure and the calling LiveView logs on success. The wrapper centralizes the `Code.ensure_loaded?` guard + rescue + default metadata — failures never crash the caller.

Action strings follow `"staff.<resource>_<verb>"`:

- `staff.person_created/updated/deleted` · `staff.person_trashed/restored` · `staff.people_bulk_trashed/restored/deleted`
- `staff.department_created/updated/deleted` · `staff.team_created/updated/deleted` · `staff.team_person_added/removed`
- `staff.skill_created/updated/deleted` · `staff.person_skill_added/removed/updated`
- `staff.person_employment_added/updated/ended/removed`
- `staff.person_file_added/removed` · `staff.person_image_added/removed` · `staff.person_avatar_set/removed`

## Permissions & settings

- `permission: "staff"` from the PhoenixKit role matrix; LiveView events trust the mount-level check.
- `staff_enabled` setting, read by `PhoenixKitStaff.enabled?/0` (rescues all errors → `false`), toggled via **Admin > Modules**.

## File layout

```
lib/phoenix_kit_staff.ex                # Main module (PhoenixKit.Module behaviour)
lib/phoenix_kit_staff/
├── activity.ex                         # Activity logging wrapper (use this, never core directly)
├── activity_labels.ex                  # Events-tab humanizer (action → {icon, label})
├── attachments.ex                      # Folder-scoped person media (Files/Images tabs)
├── departments.ex / teams.ex           # CRUD contexts
├── skills.ex                           # Skill CRUD + person↔skill assignment (sole write path)
├── employments.ex                      # Employment-span history + sync_current
├── staff.ex                            # People + memberships + org_tree + placeholder-user helpers
├── l10n.ex / paths.ex / pub_sub.ex     # Date-time l10n; /admin/staff/* paths; broadcast helpers
├── schemas/                            # department, team, person, team_membership, skill,
│                                       #   person_skill, employment
└── web/                                # Live/Form/Show trios per resource + OverviewLive +
                                        #   person tab components (employment/media/events)
```

## Versioning & releases

SemVer. Version in two synced places: `mix.exs` `@version` and `lib/phoenix_kit_staff.ex` `version/0`. Release checklist: bump both + `CHANGELOG.md` entry → `mix precommit` clean → commit ("Bump version to x.y.z") + push → `git tag x.y.z && git push origin x.y.z` → `gh release create`.

## Cross-module consumption

`phoenix_kit_projects` references `PhoenixKitStaff.Schemas.{Team, Department, Person}` directly. Keep this public API stable: `Staff.list_people/1`, `Staff.get_person_by_user_uuid/2`, `Teams.list/1`, `Departments.list/1`.

Planned: `Person.work_schedule` JSONB — weekly Mon–Sun windows `%{"monday" => %{"start" => "09:00", "end" => "17:00"}}`; string keys/HH:MM strings; **absent key = non-working day** (writers omit, readers tolerate nil/empty); `%{}` = no override (consumers fall back to the projects module default). Availability metadata, not a PTO/leave subsystem.

## Conventions

- **Paths**: all through `PhoenixKitStaff.Paths.*` (wraps `PhoenixKit.Utils.Routes.path/1`)
- **Activity**: always via the `PhoenixKitStaff.Activity` wrapper, always at the LiveView layer
- **Email validation**: `Staff.email_regex/0` + `Staff.valid_email?/1`
- **Tab IDs**: prefix with `:admin_staff_*`
- **LiveView assigns** injected by PhoenixKit's on_mount hooks: `@phoenix_kit_current_scope`, `@phoenix_kit_current_user`, `@current_locale`, `@url_path`
- **LiveView layout**: `use PhoenixKitWeb, :live_view` injects the layout automatically — do not wrap templates in `LayoutWrapper.app_layout` (that's for LiveViews outside the admin live_session)
- **Gettext**: hybrid backends. Staff-domain strings use this module's backend (`use Gettext, backend: PhoenixKitStaff.Gettext`; translations in `priv/gettext/`; `mix gettext.extract` + `mix gettext.merge priv/gettext`). Generic strings already in core's `.po` (`Save`, `Cancel`, `Edit`, …) and date/time helpers stay on `PhoenixKitWeb.Gettext`. Rule of thumb: if core has it, call core; otherwise staff backend. `%Tab{}` labels carry `gettext_backend: PhoenixKitStaff.Gettext` and stay extractable via `__tab_label_strings__/0` (`gettext_noop`).

## Testing

Three levels: **unit** (`test/phoenix_kit_staff/`), **integration** (`test/phoenix_kit_staff/integration/` — real PostgreSQL via the Ecto sandbox, `PhoenixKitStaff.DataCase`, tagged `:integration`), **LiveView smoke** (`test/phoenix_kit_staff/web/` — `PhoenixKitStaff.LiveCase` against the test Endpoint + Router).

```bash
createdb phoenix_kit_staff_test   # first time only
mix test                          # unit + integration (when DB reachable)
mix test --exclude integration    # unit only, no DB
```

- `test/test_helper.exs` runs core's versioned migrations (`PhoenixKit.Migration.ensure_current/2`) on every boot — newly-shipped Vxxx migrations auto-apply, no `mix test.setup` step. Integration tests auto-exclude when the DB is unreachable, so `mix test` never hard-fails on a missing DB.
- Support files (`test/support/`): `data_case.ex` (sandbox + shared `fixture_department/team/person` + `errors_on/1`), `live_case.ex` (`fake_scope/1`, `put_test_scope/2`; reuses DataCase fixtures), `activity_log_assertions.ex` (`assert_activity_logged/2`, `refute_activity_logged/2` — imported into both cases), plus a minimal test Repo/Endpoint/Router/layouts and an `:assign_scope` on_mount hook. DB config via `PGUSER` / `PGPASSWORD` / `PGHOST` (`config/test.exs`).

## CI

GitHub Actions on push and PRs: format check, `credo --strict`, `dialyzer`, compile with warnings-as-errors, `mix test`. Any failure blocks merge.

## Pull requests

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md` (see root `phoenix_kit/AGENTS.md` for the authoritative layout). **Every review must leave a paper trail** — if feedback was applied before the review doc was written, backfill the `{AGENT}_REVIEW.md` from the review-fix commits; a "apply review fixes" commit message is not a substitute.

Severity levels: `BUG - CRITICAL` (crashes/data loss/security) · `BUG - HIGH` (user-facing incorrect behavior) · `BUG - MEDIUM` (edge cases) · `IMPROVEMENT - HIGH` / `IMPROVEMENT - MEDIUM` · `NITPICK`.

## Commit message rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.
