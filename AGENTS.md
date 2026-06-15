# AGENTS.md

Guidance for AI agents working on the `phoenix_kit_staff` plugin module.

## Project overview

A PhoenixKit plugin module that manages staff. Implements the `PhoenixKit.Module` behaviour for auto-discovery. Registers one admin tab (`Staff`) with subtabs:

- **Overview** — org tree (departments → teams → people), upcoming birthdays, quick actions
- **Departments** — flat list of departments
- **Teams** — teams across all departments
- **Staff** — people on staff (each linked 1:1 to a `PhoenixKit.Users.Auth.User`)
- **Skills** — the skill taxonomy + per-skill proficiency levels (see the Skills section below)

## What this module does NOT have (by design)

This module's job is the org-structure backbone — Departments → Teams →
People with placeholder-user auto-link. It deliberately omits things a
full HRIS would have so the surface stays small and the host app can
plug in whatever it actually needs:

- **No leave / PTO tracking** — no time-off requests, no approval
  workflow, no balance ledger.
- **No performance reviews** — no appraisal/review cycles or ratings of
  people. (Skills *are* structured — see the Skills section — assigned to
  people with an optional per-assignment proficiency level; but there is no
  review/appraisal workflow on top of that.)
- **No org-chart visualization** beyond the Overview's nested-list
  view. Tree rendering uses plain HTML — no D3/SVG layout.
- **No bulk import** (CSV/spreadsheet wizard) — every Department,
  Team, and Person is created via single-record form. Use the context
  API (`Staff.create_person/2`, etc.) for scripted imports.
- **No public-facing pages** — staff is admin-only. There is no
  user-facing "team directory" or "people search" route.
- **No external HRIS integration** — no Workday, BambooHR, Rippling
  connectors. The placeholder-user flow + `Staff.find_or_create_user_by_email/1`
  is intentionally the only outside-onboarding surface.
- **No payroll, compensation, or contract data** — `employment_type`
  is a free-form string; no salary, no equity, no contract fields.
- **No audit history beyond `PhoenixKit.Activity`** — every mutation
  logs an action atom, but there is no per-field versioning or "who
  changed what when" timeline UI of its own. The activity feed is the
  audit trail.

When the host app needs any of the above, build it as a sibling
PhoenixKit module that consumes Staff's stable public API
(`Staff.list_people/1`, `Staff.get_person_by_user_uuid/2`,
`Teams.list/1`, `Departments.list/1`). The cross-module dep on
`phoenix_kit_projects` already follows this pattern.

## Common commands

Run from the workspace app directory (`/www/app`), not from inside this plugin subdir — the plugin's deps live in the app's `_build`. Exception: `mix format` works anywhere.

```bash
# From /www/app:
mix compile                 # Compile the whole workspace including this plugin
mix format                  # Format (uses Phoenix LiveView import rules)
sudo supervisorctl restart elixir  # Restart the dev server after edits
```

### Code quality

```bash
mix format                  # Format (uses Phoenix LiveView import rules)
mix credo --strict          # Lint / code quality
mix dialyzer                # Static type checking
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
```

## Dependencies

- `phoenix_kit` (path dep) — Module behaviour, Settings, RepoHelper, Users.Auth, Activity
- `phoenix_live_view` — admin pages
- `ecto_sql` — schemas, changesets

## Local cross-repo development

`phoenix_kit` (and any sibling `phoenix_kit_*` dep) resolves from Hex by
default. To build or test this module against a **local checkout** of a
dependency — e.g. an unpublished core change — export `<APP>_PATH` and Mix
swaps the Hex pin for a `path:` + `override: true` dep at resolve time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test     # this module against local core
```

The variable name is the dep's app name upper-cased with `_PATH` appended
(`:phoenix_kit` -> `PHOENIX_KIT_PATH`, `:phoenix_kit_ai` ->
`PHOENIX_KIT_AI_PATH`). Set several at once to override multiple deps. **Unset = the
published pin**, so `mix hex.publish` and CI resolve exactly as before.
Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a `phoenix_kit*`
dep into a `path:` tuple (a committed path dep ships a broken package); set
the env var instead.

## Architecture

### Concepts

- **Department** — a top-level org unit
- **Team** — belongs to exactly one Department
- **Person** — staff profile, always linked to a `PhoenixKit.Users.Auth.User`. Can be on many Teams via `TeamMembership`. Has an optional `primary_department_uuid` independent of team memberships.
- **TeamMembership** — join row between Team and Person
- **Skill** — a flat, translatable skill (no parent). Assigned to people many-to-many.
- **PersonSkill** — join row between Person and Skill, carrying a `proficiency_levels` array of the skill's own level ids

### Schemas

- `PhoenixKitStaff.Schemas.Department` — `phoenix_kit_staff_departments`
- `PhoenixKitStaff.Schemas.Team` — `phoenix_kit_staff_teams`
- `PhoenixKitStaff.Schemas.Person` — `phoenix_kit_staff_people`
- `PhoenixKitStaff.Schemas.TeamMembership` — `phoenix_kit_staff_team_memberships`
- `PhoenixKitStaff.Schemas.Skill` — `phoenix_kit_staff_skills`
- `PhoenixKitStaff.Schemas.PersonSkill` — `phoenix_kit_staff_person_skills`

All use `@primary_key {:uuid, UUIDv7}`, `timestamps(type: :utc_datetime)`, `@foreign_key_type UUIDv7`.

### Contexts

- `PhoenixKitStaff.Departments` — CRUD
- `PhoenixKitStaff.Teams` — CRUD
- `PhoenixKitStaff.Skills` — skill CRUD + person↔skill assignment (`assign_skill`, `unassign_skill`, `update_assignment_level`, `list_for_person`, `list_people_for_skill`, `people_without_skill`, `skills_not_assigned_to`); `Staff` exposes thin delegators
- `PhoenixKitStaff.Staff` — people CRUD (`list_people`, `get_person`, `create_person`, `update_person`, `delete_person`, `change_person`), team memberships, org tree, upcoming birthdays, and placeholder-user helpers (`find_or_create_user_by_email`, `create_person_with_user`, `rename_placeholder_email`)

### LiveViews

Under `PhoenixKitStaff.Web.*`:
- `OverviewLive` — org tree + birthdays
- `DepartmentsLive`, `DepartmentFormLive`, `DepartmentShowLive`
- `TeamsLive`, `TeamFormLive`, `TeamShowLive`
- `PeopleLive`, `PersonFormLive`, `PersonShowLive`
- `SkillsLive`, `SkillFormLive`, `SkillShowLive`

### URL paths

All under `/admin/staff/*`: `departments`, `teams`, `people`, `skills`, plus `.../new`, `.../:id`, `.../:id/edit` for each. Use `PhoenixKitStaff.Paths` — never hardcode.

## Database

**Migrations live in `phoenix_kit` core** (versioned system). The four staff tables ship in `V100`. Later cross-cut changes:

- `V122` bundles `translations JSONB NOT NULL DEFAULT '{}'` on all three top-level staff tables (`phoenix_kit_staff_departments`, `phoenix_kit_staff_teams`, `phoenix_kit_staff_people`) plus a single `name VARCHAR` on `phoenix_kit_staff_people` for the person's full display name.
- `V131` adds `metadata JSONB NOT NULL DEFAULT '{}'` on `phoenix_kit_staff_people` (general-purpose, mirrors `entity_data`). Soft-delete uses it to stash `trashed_from_status` so restore returns the person to active/inactive. Shipped in core **1.7.132** (renumbered from a drafted V130 — core took V130 for the annotations-marker migration). The module's soft-delete requires this column, so the `phoenix_kit` lock must resolve to `>= 1.7.132`; until the lock is bumped the soft-delete tests/CI run against a core without the column and go red by design (works locally via the `phoenix_kit_parent` path-override or `PHOENIX_KIT_PATH`).
- `V135` creates `phoenix_kit_staff_skills` (translatable `name`/`description`, globally unique `lower(name)`, plus a `levels` JSONB array of per-skill translatable proficiency levels and an `allow_multiple_levels` boolean) + `phoenix_kit_staff_person_skills` (join with a `proficiency_levels` JSONB array of selected level ids), migrates the old free-text `phoenix_kit_staff_people.skills` into structured rows (case-insensitive dedup, guarded for retry-safety), and **drops** that column. **Lossy by design:** per-locale `translations["skills"]` overrides don't map to structured skills and are stripped. Requires the `phoenix_kit` lock to resolve to the core release carrying V135 (works locally via the path-override / `PHOENIX_KIT_PATH` until then).

When changing the schema, add the next `VNN` migration in `/www/phoenix_kit/lib/phoenix_kit/migrations/postgres/`.

## Multilang translations

Department, Team, Person, and Skill all carry a `translations` JSONB column for non-primary-language overrides on a subset of free-text fields. Primary-language values stay denormalized in their dedicated columns; the JSONB holds only language-prefixed overrides:

```elixir
%{"es-ES" => %{"name" => "...", "description" => "..."}}
```

Translatable fields by schema:

- **Department:** `name`, `description`
- **Team:** `name`, `description`
- **Skill:** `name`, `description`
- **Person:** `job_title`, `bio`, `notes` (NOT `name` — it's a single full-name field, see below; NOT `work_location` — soft-FK to a Location row that owns its own translations; `skills` is gone — replaced by the structured `Skill` entity in V135)

Read paths use `<Schema>.localized_<field>/2` helpers (e.g. `Person.localized_job_title(person, "es-ES")`) with primary-fallback semantics: if a language-specific value is missing or empty, returns the primary-column value.

Forms use `<.multilang_tabs>` + `<.multilang_fields_wrapper>` + `<.translatable_field>` from `PhoenixKitWeb.Components.MultilangForm`. The wrapper re-mounts on language switch, so non-translatable fields must render as siblings outside the wrapper or they lose state on every switch.

`L10n.valid_translations_shape?/1` validates the JSONB structure in each schema's changeset (`%{lang_code => %{field => value}}` shape).

## Skills

A first-class, translatable taxonomy (added one at a time, like Teams) assigned
to people many-to-many. Replaces the old free-text `Person.skills` (V135 migrates
+ drops it). Managed via the **Skills** admin subtab.

- **`Skill`** (`phoenix_kit_staff_skills`) — flat (no parent), translatable
  `name`/`description`, globally unique `lower(name)`. CRUD in
  `PhoenixKitStaff.Skills` (mirrors `Teams`). Each skill defines its **own**
  proficiency levels: a `levels` JSONB array of `%{"id", "name", "translations"}`
  maps (per-skill, optional, **translatable** via the form's language selector —
  level names are user data in `levels[].translations`, not gettext) with stable
  `id`s, plus an `allow_multiple_levels` boolean. `Skill` exposes `levels/1`,
  `level_ids/1`, `find_level/2`, `localized_level_name/3` (graceful on unknown id),
  `level_options/2`, `gen_level_id/0`; `normalize_levels/1` strictly validates the
  JSONB shape (id-gen for new rows, dup-id error, blank-name drop). **There is no
  hardcoded global level enum** — the old `proficiency_label/1` is gone.
- **`PersonSkill`** (`phoenix_kit_staff_person_skills`) — the join, whose
  `proficiency_levels` JSONB array holds the selected level `id`s into the parent
  skill's `levels` (`[]` = not set; single-select skill = 0–1, multi-select = 0–N).
  The changeset only normalises (drop blanks, dedup); **semantic** validation (ids
  ⊆ the skill's levels, ≤1 when single-select, order normalised to skill order)
  lives in `Skills` — the **sole** write path.
- **Assignment** lives in `PhoenixKitStaff.Skills` (`assign_skill(.., level_ids)`/
  `unassign_skill`/`update_assignment_levels` + `validate_level_ids` + rosters),
  with thin `Staff` delegators. `Skills.update/2` reconciles existing assignments
  in one transaction (strips removed level ids; prunes to ≤1 on multiple→single).
  Manage it
  from **two directions**: the **skill show** (skill → people, with the skill's
  own levels as **event-driven toggle chips** — single-select replaces, multi
  toggles — persisted immediately) and the **person edit form**
  (person → skills, **staged** — a type-to-search multi-select where each staged
  row shows the skill's level chips; writes to the DB only when the form is
  **saved**; `PersonFormLive`
  reconciles the staged list against the DB in `sync_skills/2` after the person
  upsert). The picker only assigns **existing** skills (the taxonomy is created
  on the Skills page), so it carries an "Add / edit skills" link (new tab) and,
  when no skills exist yet, collapses to an empty-state prompt; `phx-window-focus`
  re-queries the taxonomy on return so a freshly-created skill appears without a
  manual reload. The **person show** Overview tab renders the assignments
  **read-only** (badge per skill + level), linking to the edit form to change them.
- Deleting a skill cascades its assignments (FK `ON DELETE CASCADE`); the list +
  delete-confirm surface the "removed from N people" count.
- Categories/grouping are **not** built (a deliberate v1 cut — easy follow-up).

## Person.name

A single `name` field (VARCHAR, nullable, max 255) holds the staff person's full display name — consistent with `Department.name`, `Team.name`, `Space.name`, and `Location.name` in the broader plugin ecosystem. The field lives on Person (not on the linked User) because:

- Staff profiles have a defined lifecycle (hire / leave) separate from the underlying auth account.
- Placeholder users created via `Staff.find_or_create_user_by_email/1` are anonymous (email-only); the staff profile owns the human identity until the placeholder is claimed.

An earlier sketch tried `first_name` / `middle_name` / `last_name` as three columns; the migration was reshaped to a single `name` because most staff systems just want a display name and per-cultural name parsing is out of scope.

## Work location — soft dep on phoenix_kit_locations

`Person.work_location` is a soft FK to a `phoenix_kit_locations` Location row. The column stays VARCHAR (the UUID is stored as a string) to avoid a type-changing migration; the form picks from a select sourced from `PhoenixKitLocations.list_locations/0` when the locations module is enabled.

Hidden when locations is not available:

```elixir
defp locations_module_enabled? do
  Code.ensure_loaded?(PhoenixKitLocations) and PhoenixKitLocations.enabled?()
end
```

Form-level: the `<.select>` block is rendered with `:if={@location_options != []}` so the field disappears entirely when the soft dep isn't present. Person show falls back to the raw stored value (the UUID or any pre-existing free-text address) when the locations module is unreachable.

## Placeholder user flow

The staff form accepts any email. If the user doesn't exist, `Staff.find_or_create_user_by_email/1` creates a placeholder (unconfirmed, random password, `custom_fields.source = "staff_placeholder"`). When the person later registers or signs in via OAuth with the same email, PhoenixKit's built-in email lookup auto-links them.

`Staff.create_person_with_user/2` is a transaction-like wrapper that rolls back a freshly-created placeholder if the staff profile insert fails.

The form allows renaming a placeholder's email until it's claimed (via `Staff.rename_placeholder_email/2`, which refuses if the user is confirmed or isn't tagged as a placeholder).

## Soft-delete (people)

`Person` follows the workspace soft-delete convention — a sentinel
`status = "trashed"` on the existing status column, **never** a
`deleted_at`. This is mandatory here because `Person.uuid` is an FK
target from `phoenix_kit_projects` (`Assignment.assigned_person_uuid`,
core V128, `ON DELETE SET NULL`): a hard delete would silently NULL out
a person's project assignments. Soft-delete keeps the row (and the
assignment/membership FK rows) intact.

Context API (`PhoenixKitStaff.Staff`):

- `trash_person/1` — `status` → `"trashed"`, stashing the prior status
  in `metadata["trashed_from_status"]` (V131 column). `{:error, :already_trashed}` if already trashed.
- `restore_person/1` — restores to the stashed status (validated against
  `Person.statuses/0`, else `"active"`), clearing the stash key.
  `{:error, :not_trashed}` otherwise.
- `delete_person/1` — **permanent** hard delete (Trash view only).
  Returns `{:error, :referenced_by_external}` on a FK/NOT-NULL violation
  — defensive only; today no RESTRICT FK targets people, so it succeeds
  and clears assignment links (the UI confirm says so).
- `bulk_trash/1` / `bulk_restore/1` / `bulk_delete/1` — set-based; trash
  stashes per-row prior status via a single `jsonb_set` UPDATE.
- `create_person/1` detects an existing **trashed** profile for the same
  `user_uuid` and returns `{:error, {:trashed_person_exists, person}}`
  (the strict 1:1 unique constraint is kept; the form offers Restore
  instead of erroring).

Scoping: `list_people/1` **excludes trashed by default** (pass
`status: "trashed"` for the Trash view or `include_trashed: true` for
all); `count_people/0` excludes trashed (`count_trashed/0` is separate);
`org_tree/0`, `people_not_on_team/1`, and `upcoming_birthdays/1` all
exclude trashed. `eligible_users/1` deliberately still excludes a
trashed person's user (they flow through Restore, not re-create).

UI: `PeopleLive` has a "Trashed (N)" status filter, a per-row kebab that
swaps to Restore / Delete-permanently in the Trash view, and core
bulk-select (`<.bulk_select_scope>`); bulk permanent-delete routes
through a `<.confirm_modal>` because the `BulkSelectScope` hook can't
carry a `data-confirm`. `PersonShowLive` shows a trashed banner +
Restore / Delete-permanently.

## Activity logging

Every mutation logs via the `PhoenixKitStaff.Activity` wrapper — **never call `PhoenixKit.Activity.log/1` directly from this plugin**. The wrapper centralizes the `Code.ensure_loaded?(PhoenixKit.Activity)` guard, rescue, and default metadata (module key, actor_role) so every call site stays consistent. Action strings follow `"staff.<resource>_<verb>"`:

- `staff.person_created/updated/deleted`
- `staff.person_trashed/restored` (soft-delete; `deleted` is now the *permanent* delete)
- `staff.people_bulk_trashed/restored/deleted` (bulk soft-delete actions)
- `staff.department_created/updated/deleted`
- `staff.team_created/updated/deleted`
- `staff.team_person_added/removed`
- `staff.skill_created/updated/deleted`
- `staff.person_skill_added/removed/updated` (skill assigned to / unassigned from / re-leveled on a person)

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
├── skills.ex                                # Context: skill CRUD + person↔skill assignment
├── schemas/
│   ├── department.ex
│   ├── person.ex                            # Employment metadata + emergency contacts
│   ├── person_skill.ex                      # Person↔Skill join + proficiency_levels (level ids)
│   ├── skill.ex
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
    ├── skill_form_live.ex
    ├── skill_show_live.ex                   # Skill → people assignment (+ level)
    ├── skills_live.ex
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

### Planned: `Person.work_schedule` (JSONB)

A future change will add a `work_schedule` JSONB column to
`phoenix_kit_staff_people` so the projects module can look up an
assignee's weekly Mon–Sun work windows when computing a task's
planned end. The consumer side (a per-task "count as work hours"
toggle in `phoenix_kit_projects`) lands in a coordinated follow-up
PR pair; this section is a heads-up so the next person editing
`Person.changeset/2` doesn't bounce off the staff module's "no HRIS
features" stance.

**Shape (JSONB, string keys throughout):**

```elixir
%{
  "monday"    => %{"start" => "09:00", "end" => "17:00"},
  "tuesday"   => %{"start" => "09:00", "end" => "17:00"},
  # ...
  # Saturday and Sunday omitted = non-working days
}
```

- **String keys, HH:MM strings** — not atoms, not `Time` structs.
  JSONB round-trips as strings and consumers should parse on read.
- **Canonical "non-working day" = key absent.** Do not write
  `%{"saturday" => nil}` or `%{"saturday" => %{}}` — omit the key.
  Readers should treat missing-key, `nil`, and empty-map identically
  (non-working) to stay tolerant of older rows, but writers emit
  only the omit-the-key form.
- **Default empty map.** When `work_schedule == %{}` the row has
  no per-person override; consumers fall back to the projects
  module's default schedule. As of today that fallback is the
  "5 workdays × 8 hours" approximation in
  `phoenix_kit_projects` `work_hours_elapsed/2` — a Mon–Fri
  09:00–17:00 windowed helper does not exist yet and is part of
  the follow-up work, not something already shipped.

This is availability metadata, parallel in spirit to existing
per-person fields (`work_location`, `work_phone`) — not a PTO
ledger and not the start of a leave-tracking subsystem (see the
"What this module does NOT have" carve-out above).

## Conventions

- **Paths**: all through `PhoenixKitStaff.Paths.*` (which uses `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling)
- **Activity**: always via `PhoenixKitStaff.Activity` wrapper, always at the LiveView layer
- **Email validation**: centralized in `PhoenixKitStaff.Staff.email_regex/0` + `valid_email?/1`
- **Tab IDs**: prefix with `:admin_staff_*`
- **LiveView assigns**: `@phoenix_kit_current_scope`, `@phoenix_kit_current_user`, `@current_locale`, `@url_path` are injected by PhoenixKit's on_mount hooks
- **LiveView layout**: `use PhoenixKitWeb, :live_view` (in `phoenix_kit_web.ex`) injects `layout: PhoenixKit.LayoutConfig.get_layout()` automatically. No need to wrap templates in `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` — that wrapper is for LiveViews served outside the admin live_session
- **Gettext**: hybrid backends. Staff-**specific** (domain) strings — staff, person, department, team, membership UI — use this module's own backend: `use Gettext, backend: PhoenixKitStaff.Gettext` then `gettext(...)`, with translations in `priv/gettext/` (run `mix gettext.extract` + `mix gettext.merge priv/gettext` here). **Generic** strings already translated workspace-wide (`Save`, `Cancel`, `Edit`, `Name`, `Status`, etc.) stay on core via `Gettext.gettext(PhoenixKitWeb.Gettext, "...")`. Date/time helpers in `l10n.ex` stay on core too. Admin `%Tab{}` labels carry `gettext_backend: PhoenixKitStaff.Gettext` and are kept extractable via `__tab_label_strings__/0` (`gettext_noop`). Rule of thumb: if core's `.po` already has the string, call it on core; otherwise it's domain → staff backend.

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

Three levels:

- **Unit tests** in `test/phoenix_kit_staff/` — schemas, changesets,
  pure helpers, the `Errors` atom dispatcher. Always run.
- **Integration tests** in `test/phoenix_kit_staff/integration/` —
  hit a real PostgreSQL database via the Ecto sandbox. Use
  `PhoenixKitStaff.DataCase`.
- **LiveView smoke tests** in `test/phoenix_kit_staff/web/` — drive
  LVs via `Phoenix.LiveViewTest.live/2` against the test Endpoint
  + Router. Use `PhoenixKitStaff.LiveCase`.

Test infrastructure:

- `test/support/test_repo.ex` — `PhoenixKitStaff.Test.Repo`
- `test/support/test_endpoint.ex` — minimal `Phoenix.Endpoint` for
  LV tests; `server: false`, no port opened
- `test/support/test_router.ex` — minimal Router whose paths match
  `PhoenixKitStaff.Paths.*` (base scope `/en/admin/staff`)
- `test/support/test_layouts.ex` — root + app layouts; `app/1`
  renders flash divs (`#flash-info`, `#flash-error`,
  `#flash-warning`) so smoke tests can assert flash content via
  `render(view) =~ "Saved."` after click events
- `test/support/hooks.ex` — `:assign_scope` `on_mount` hook that
  reads `"phoenix_kit_test_scope"` from session and assigns
  `phoenix_kit_current_scope` + `phoenix_kit_current_user` (mirrors
  what `live_session :phoenix_kit_admin` does in production)
- `test/support/data_case.ex` — `PhoenixKitStaff.DataCase`, tags
  tests `:integration`, sets up the SQL Sandbox; hosts shared
  `fixture_department/1`, `fixture_team/1`, `fixture_person/1` and
  `errors_on/1`
- `test/support/live_case.ex` — `PhoenixKitStaff.LiveCase` with
  `fake_scope/1` + `put_test_scope/2` for plugging a real
  `%PhoenixKit.Users.Auth.Scope{}` into the test session; reuses
  the fixtures from `DataCase`
- `test/support/activity_log_assertions.ex` —
  `assert_activity_logged/2` and `refute_activity_logged/2` query
  `phoenix_kit_activities` directly with action / actor / metadata-
  subset matching; imported into both `DataCase` and `LiveCase`
- `test/test_helper.exs` — starts `PhoenixKit.PubSub.Manager`,
  Hammer's `RateLimiter.Backend`, pins
  `:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")`,
  starts `PhoenixKitStaff.Test.Endpoint`, and runs core's versioned
  migrations via `PhoenixKit.Migration.ensure_current/2` (V40
  extensions + uuid_generate_v7, V03 settings, V90 activities,
  V100 staff tables) — no module-owned DDL anywhere
- `config/test.exs` — repo config + Test.Endpoint config (env-var
  driven via `PGUSER` / `PGPASSWORD` / `PGHOST`)

Commands:

```bash
# First time only:
createdb phoenix_kit_staff_test

# All runs (unit + integration if DB is reachable):
mix test

# Unit tests only (DB not required):
mix test --exclude integration
```

The test helper runs core's versioned migrations via
`PhoenixKit.Migration.ensure_current/2` on every boot, so the schema
re-applies any newly-shipped Vxxx migrations automatically. No
`mix test.setup` step needed past the initial `createdb`.

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
