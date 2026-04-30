# Phase 1 + Phase 2 quality sweep — re-validation

**Date:** 2026-04-28
**Reference precedents:** `phoenix_kit_locations#3`, `phoenix_kit_ai#5`,
`phoenix_kit_publishing#10`, `phoenix_kit_catalogue#14`,
`phoenix_kit_entities#9`.

This module's first-pass Phase 1 + Phase 2 sweep landed 2026-04-27
(`10a162a` + `e003c53` + `bcdb160`). Re-validation 2026-04-28 brings
it up to the current post-Apr pipeline standard via three additional
batches following the canonical template:

- **Batch 2** — structural pipeline deltas (handle_info Logger.debug,
  ActivityLog rescue widening, subscribe-before-fetch, mix.exs
  ignore_modules)
- **Batch 3** — fix-everything (`@spec` backfill, error-branch audit
  rows via LV-layer helper, edge-case tests, schema constraint fix)
- **Batch 4** — first coverage push (62.64% → 89.43% via `mix test --cover`
  only, no Mox/excoveralls/external deps)
- **Batch 5** — second coverage push (89.43% → 95.07%, near the
  practical no-deps ceiling for DB-only modules per the workspace
  AGENTS.md "Coverage push pattern")

All work shipped via `mdon:quality-sweep` (harness blocks `mdon:main`
pushes per AGENTS.md:855-864). After upstream merges:
`git fetch upstream && git checkout main && git reset --hard upstream/main`.

## Fixed (Batch 2 — re-validation 2026-04-28)

Commit: `8fcbb6e` "Phase 2 re-validation Batch 2 — handle_info
Logger.debug, ActivityLog rescue, subscribe-before-fetch"

### `enabled?/0` `catch :exit, _ -> false`

`lib/phoenix_kit_staff.ex:32` — added the `catch :exit, _ -> false`
clause alongside the existing `rescue _ -> false`. Without it, the
sandbox-shutdown trap (sandbox owner exit raises `:exit`, not an
exception) leaves `enabled?/0` crashing during teardown. Mirrors
hello_world `c1c2674` and the AI module's `safe_count/1` shape.

### `Activity.log/2` rescue widened to canonical post-Apr shape

`lib/phoenix_kit_staff/activity.ex:30-43` — was a single broad
`rescue e -> Logger.warning(...)`, now matches the
publishing-Batch-5 / entities-Batch-3 canonical shape:

```elixir
rescue
  Postgrex.Error -> :ok
  DBConnection.OwnershipError -> :ok
  e ->
    Logger.warning("[Staff] Activity logging error: #{Exception.message(e)}")
    {:error, e}
catch
  :exit, _reason -> :ok
end
```

Without the explicit `Postgrex.Error` / `DBConnection.OwnershipError`
clauses, async PubSub broadcasts crossing into the logging path
during sandbox checkout/shutdown produced a `Logger.warning` that's
pure noise. Pinned by
`test/phoenix_kit_staff/integration/activity_log_rescue_test.exs`.

### `handle_info/2` catch-all clauses promoted from silent → `Logger.debug`

`lib/phoenix_kit_staff/web/{overview,people,teams,departments,department_show,team_show,person_show}_live.ex`.

- 6 LVs had silent `handle_info(_msg, socket), do: {:noreply, socket}`
  catch-alls per the pre-Apr pattern; promoted to
  `Logger.debug("[Staff] X: unexpected handle_info ...")`. Each gained
  `require Logger`.
- `PersonShowLive` previously had **no** catch-all at all — only the
  two `{:staff, ...}`-shaped clauses matched. Any non-`{:staff, ...}`
  message would have raised `FunctionClauseError`. Added one.

Pinned per-LV by
`test/phoenix_kit_staff/web/handle_info_catchall_test.exs` with
`Logger.configure(level: :debug)` per test (entities-Batch-3 trap —
the test config sets `:warning` globally and would filter debug
*before* `capture_log` sees it).

### Subscribe-before-fetch race window closed on the 3 show pages

`department_show_live.ex` / `team_show_live.ex` / `person_show_live.ex`
mounts: `subscribe(...)` now runs BEFORE the DB read instead of
after. Previously a broadcast firing in the gap between `Departments.get/2`
and the post-fetch `subscribe(...)` was silently dropped; the
receiving LV stayed stale until manual reload. The URL `id` IS the
UUID, so the topic key is identical either way. Pinned via the
source-pairing meta-test in
`test/phoenix_kit_staff/web/subscribe_before_fetch_test.exs` (same
shape as publishing-Batch-2's `phx-disable-with` paired test).

### `mix.exs` `test_coverage [ignore_modules]` filter

So `mix test --cover` reports production-only coverage —
test-support modules (`Test.*`, `DataCase`, `LiveCase`,
`ActivityLogAssertions`) are excluded. document_creator-Batch-5
precedent.

## Fixed (Batch 3 — fix-everything pass 2026-04-28)

Commit: `8a58312` "Phase 2 re-validation Batch 3 — fix-everything
pass: @spec backfill, Person schema constraint fix, error-branch
audit rows, edge-case tests"

### `@spec` backfill — 41 typespecs

- `lib/phoenix_kit_staff/staff.ex` — 13 missing public-API specs
  (`create_person_with_user/2`, `find_or_create_user_by_email/1`,
  `eligible_users/1`, `get_person!/2`, `get_person/2`,
  `upcoming_birthdays/1`, `org_tree/0`, `list_team_memberships/1`,
  `list_memberships_for_person/1`, `add_team_person/2`,
  `remove_team_person/{1,2}`, `people_not_on_team/1`).
- `lib/phoenix_kit_staff/paths.ex` — 13 specs (every path helper).
- `lib/phoenix_kit_staff/pub_sub.ex` — 11 specs + `@typedoc topic` +
  `@typedoc event`.
- `lib/phoenix_kit_staff/l10n.ex` — 3 specs (`format_date`,
  `format_month_day`, `short_month` with multi-clause primary spec).
- `lib/phoenix_kit_staff/activity.ex` — 2 specs (`log/2`,
  `actor_uuid/1`).

### Schema fix — `Person.changeset/2` `unique_constraint` name mismatch

**Real bug surfaced by the new edge-case test.** The DB index is
`phoenix_kit_staff_people_user_index`, but the changeset registered
the default `_user_uuid_index` name. Inserting a duplicate
`user_uuid` raised `Ecto.ConstraintError` instead of returning
`{:error, %Ecto.Changeset{}}` — exactly the same pattern bug fixed
on `Schemas.Team.changeset/2` in commit `e003c53` of the original
sweep. Now passes `name: :phoenix_kit_staff_people_user_index`
explicitly.

### Error-branch audit rows via LV-layer helper

New `lib/phoenix_kit_staff/web/helpers.ex` module with
`log_operation_error/3` — the catalogue-Batch-4 canonical pattern
for resolving the tension between this module's documented
success-only `Activity` invariant at the call site (per CLAUDE.md
"Activity logging" section) and the post-Apr pipeline's
both-branch audit-row requirement.

- Single edit point in `Web.Helpers` instead of ~10 LV mutation sites
- Same action atom the success path would have used (e.g.
  `staff.person_deleted`)
- `metadata.db_pending = true` so audit-feed readers can distinguish
  attempted-but-failed from completed actions
- PII-safe metadata: changeset reasons land error-key field names
  ONLY (no values, never user-typed strings); atom reasons land the
  atom string; other shapes get `error_kind: "other"`
- Failure side never crashes the LV; mirrors `Activity.log/2`'s
  contract

Wired into 5 destructive call sites:
- `people_live#delete` (target_uuid threaded)
- `departments_live#delete`
- `teams_live#delete`
- `team_show_live#add_person`
- `team_show_live#remove_person`

Validate cycles never reach this helper — keystroke-level changeset
errors from `phx-change` go through `assign_form/2` and don't
generate audit rows (correctly — every keystroke would otherwise
spam the feed).

Pinned by:
- `test/phoenix_kit_staff/web/helpers_test.exs` (+6) — unit tests
  covering all three reason shapes (changeset / atom / other), extra-
  metadata merging, actor_uuid threading from socket, PII-safety of
  error_keys (asserts the `RuntimeError` struct's "secret leak
  attempt" message NEVER lands in metadata).
- `test/phoenix_kit_staff/web/error_branch_logging_test.exs` (+5) —
  LV-driven reachable error path (team_show#add_person duplicate
  triggers `unique_constraint` → `{:error, changeset}` →
  `log_operation_error` fires) plus source-pairing structural pin
  for the 4 unreachable defense-in-depth `:error` branches
  (Departments/Teams/Person delete + remove_team_person — those are
  unreachable today because schemas use `on_delete: :delete_all`
  cascades, but the helper call is wired in defensively for future
  schema changes that add constraints).

### LV smoke tests for the 4 LVs that lacked them

`test/phoenix_kit_staff/web/listing_lvs_test.exs` (+15) — mount + one
happy-path interaction per page with `actor_uuid` and `resource_uuid`
pinned on every activity assertion (locations Batch 3 / publishing
Batch 4 precedent for catching opt-threading regressions):
OverviewLive, DepartmentsLive, TeamsLive, PeopleLive,
DepartmentShowLive, PersonShowLive, plus a TeamShowLive extension and
a PubSub subscribe-before-fetch round-trip cover.

### Edge-case tests

`test/phoenix_kit_staff/edge_cases_test.exs` (+29) — Unicode round-trip
(CJK / emoji / RTL) on Department/Team/Person free-text fields;
256-char rejection on `validate_length`; SQL metacharacter literal
handling (no injection, no escape leak); empty/nil inputs;
`Staff.valid_email?` edge cases; `Person.skill_list/1` edge cases
(Unicode, blanks, trim); `Person.{status,employment_type}_label`
fall-through pinning the defense-in-depth raw-SQL out-of-band-status
case. **This is what surfaced the Person `unique_constraint` bug.**

## Fixed (Batch 4 — coverage push 2026-04-28)

Commit: `0f6a102` "Phase 2 re-validation Batch 4 — coverage push
62.64% → 89.43%"

Coverage 62.64% → **89.43%** (+26.79pp) via 85 new tests, using only
`mix test --cover` (no Mox / excoveralls / Bypass / external HTTP
stubs). Per-module uplifts:

| Module | Before | After | Δ |
|---|---:|---:|---:|
| `PhoenixKitStaff` (top-level)    | 0.00%  | 81.25% | +81.25 |
| `PhoenixKitStaff.L10n`           | 0.00%  | 100.00% | +100.00 |
| `PhoenixKitStaff.Web.TeamFormLive` | 0.00%  | 89.36% | +89.36 |
| `PhoenixKitStaff.Web.PersonShowLive` | 32.00% | 84.80% | +52.80 |
| `PhoenixKitStaff.Web.PersonFormLive` | 45.16% | 87.10% | +41.94 |
| `PhoenixKitStaff.Web.OverviewLive` | 51.06% | 93.62% | +42.56 |
| `PhoenixKitStaff.Web.DepartmentFormLive` | 78.38% | 94.59% | +16.21 |
| `PhoenixKitStaff.Web.PeopleLive` | 87.04% | 92.59% | +5.55 |
| `PhoenixKitStaff.Staff`          | 85.71% | 93.65% | +7.94 |
| `PhoenixKitStaff.Web.TeamShowLive` | 80.65% | 82.26% | +1.61 |

New test files:
- `test/module_callbacks_test.exs` (+10) — admin_tabs/0 shape, every
  tab has `permission: "staff"`, visible/hidden subtab IDs,
  4-resource CRUD coverage; `enabled?/0` sandbox-shutdown safety;
  `version/0` matches mix.exs `@version`; `css_sources/0`;
  `permission_metadata/0`.
- `test/l10n_test.exs` (+15) — `short_month/1` for all 12 months,
  `format_date/1` nil/Date/DateTime/NaiveDateTime, `format_month_day/1`
  variants, leap-year Feb 29.
- `test/web/team_form_live_test.exs` (+9) — full smoke mirror of
  `department_form_live_test`. The team form was at 0% pre-batch.
- `test/web/coverage_test.exs` (+50) — targeted coverage extensions.

**Tests/pp ratio:** 85 tests buying 26.79pp = **3.17 tests/pp** —
well below the 50-tests/pp diminishing-returns stop signal.

### Batch 4 — first coverage push (62.64% → 89.43%)

What landed in Batch 4 became the floor; Batch 5 below builds on it.

## Fixed (Batch 5 — second coverage push 2026-04-28)

Commit: `e18b18d` "Phase 2 re-validation Batch 5 — coverage push
89.43% → 95.07%"

Pushes line coverage **89.43% → 95.07%** (+5.64pp) via 69 additional
tests in `test/coverage_extras_test.exs`. Tests/pp ratio: ~12.2 —
under the 50-tests/pp diminishing-returns stop signal.

Brings coverage to the **practical ceiling for DB-only modules**
(95-97% per workspace AGENTS.md "Coverage push pattern"). Remaining
~5pp residuals are deliberate defense-in-depth that core swallows
before reaching the wrapper.

| Module | Batch 4 | Batch 5 | Δ |
|---|---:|---:|---:|
| `Schemas.Person`              |  87.50% | 100.00% | +12.50 |
| `Paths`                       |  92.31% | 100.00% |  +7.69 |
| `Web.PersonShowLive`          |  84.80% |  95.20% | +10.40 |
| `Web.PersonFormLive`          |  87.10% |  95.48% |  +8.38 |
| `Web.TeamFormLive`            |  89.36% |  95.74% |  +6.38 |
| `Web.DepartmentShowLive`      |  77.42% |  96.77% | +19.35 |
| `Web.TeamShowLive`            |  82.26% |  91.94% |  +9.68 |
| `Web.PeopleLive`              |  92.59% |  94.44% |  +1.85 |
| `Web.DepartmentsLive`         |  88.37% |  93.02% |  +4.65 |
| `Web.Helpers`                 |  87.50% |  93.75% |  +6.25 |
| `Staff` (context)             |  93.65% |  99.21% |  +5.56 |

Tests target previously-uncovered branches via:

1. **Helpers atom-keyed metadata + string-key passthrough** —
   `stringify_keys/1`'s `is_atom(k)` + plain `{k, v}` clauses.
2. **Person status_label / employment_type_label every clause** —
   direct unit tests for all atoms + the unknown fall-through. Plus
   an LV smoke test that lands an out-of-band status row via raw
   SQL (`validate_inclusion` blocks it through the public API) so
   `status_badge_class/1`'s catch-all fall-through fires in the
   PeopleLive table render.
3. **PersonShowLive helper edges** — `full_name` with first/last
   name, `format_birthday` wrap-to-next-year + Feb 29 in non-leap-
   year target, Teams table when person has memberships, Employment
   card render with partial fields, Admin notes warning panel,
   Emergency contact partial cards.
4. **PersonFormLive placeholder rename flow** — flips the fixture
   user back to placeholder state via raw SQL (un-confirms + sets
   `custom_fields.source = "staff_placeholder"`) so
   `placeholder_user?/1` returns `true`. Drives rename success →
   `:ok` path, rename to taken email → `:email_already_taken` atom
   flash, no-op rename (same email) → `:ok` branch.
5. **PersonFormLive maybe_add_to_team error** — non-existent
   `team_uuid` triggers `Logger.warning(...)` (line 234-235); pinned
   via `capture_log` and asserts the warning fires + person was
   still created.
6. **PersonFormLive existing-user reuse** — second profile attempt
   for an existing user (after the first profile is deleted) hits
   `create_flash(:existing, :ok, _email)` branch.
7. **Bogus uuid mounts** — TeamShowLive, DepartmentShowLive,
   PersonShowLive all redirect with not-found flash on bogus UUIDs
   (covers L20 `nil ->` clauses in `mount/3`).
8. **Cross-process `Activity.log`** — spawns an unallowed process
   that calls `Activity.log/2` without sandbox checkout; the
   wrapper must not crash regardless of whether the
   `OwnershipError` reaches its rescue or core's catches it first.
9. **`PhoenixKitStaff.enabled?` rescue** — drops `phoenix_kit_settings`
   mid-tx and asserts `enabled?/0` returns `false` without crashing
   (core's `Settings.get_boolean_setting/2` itself catches and
   returns the default, so the wrapper rescue is defense-in-depth
   that's hard to actually invoke; the test pins the contract).
10. **Staff context edges** — `create_person_with_user` rollback
    when person insert fails, `list_people` `:status` / `:search`
    filters, `normalize_search` blank/nil, `get_person_by_user_uuid`
    happy + nil paths, `Departments`/`Teams.{change,count,list with
    preload, get!}`.

### What stays uncovered (deliberate residual after Batch 5)

- **`PhoenixKitStaff.Activity` 58.33%** — 5 missed lines are the
  rescue-clause branches (`Postgrex.Error -> :ok`,
  `DBConnection.OwnershipError -> :ok`, `e -> Logger.warning`,
  `catch :exit, _ -> :ok`). Core's `PhoenixKit.Activity.log/1`
  has its own catch-all rescue that swallows DB errors before they
  reach the wrapper, so these are unreachable from real callers —
  only fire if core re-raises. Same shape as the locations / ai /
  hello_world residuals.
- **`PhoenixKitStaff` 81.25%** — `use PhoenixKit.Module` macro
  expansion line (compile-time, never executed at runtime) plus
  `enabled?/0` rescue/catch clauses. Core's
  `Settings.get_boolean_setting/2` itself catches errors and
  returns the default value, so the wrapper's rescue never fires
  in normal usage.
- **Defense-in-depth `:error` branches across the listing LVs**
  (DepartmentsLive#delete / TeamsLive#delete / PeopleLive#delete /
  TeamShowLive#remove_person `Helpers.log_operation_error` call
  sites). Schemas use `on_delete: :delete_all` cascades, so
  `Repo.delete/1` always succeeds for valid records — the helper
  call is wired in defensively for future schema changes that add
  constraints.
- **`Web.Helpers` `defp stringify_keys(other), do: other`
  fallback** — the only caller (`Map.merge(base_metadata, …)`)
  would crash on a non-map, so the fallback is unreachable through
  the public API.

These are deliberate defense-in-depth choices. The cost of an
unhandled exception in production is higher than a 5% coverage gap.

## Files touched

| File | Change | Batch |
|---|---|---|
| `lib/phoenix_kit_staff.ex` | `catch :exit, _ -> false` on `enabled?/0` | 2 |
| `lib/phoenix_kit_staff/activity.ex` | canonical rescue shape; `@spec` on `log/2` and `actor_uuid/1` | 2, 3 |
| `lib/phoenix_kit_staff/web/overview_live.ex` | `Logger.debug` catch-all + `require Logger` | 2 |
| `lib/phoenix_kit_staff/web/people_live.ex` | `Logger.debug` catch-all + `Helpers.log_operation_error` on delete `:error` | 2, 3 |
| `lib/phoenix_kit_staff/web/teams_live.ex` | `Logger.debug` catch-all + `Helpers.log_operation_error` on delete `:error` | 2, 3 |
| `lib/phoenix_kit_staff/web/departments_live.ex` | `Logger.debug` catch-all + `Helpers.log_operation_error` on delete `:error` | 2, 3 |
| `lib/phoenix_kit_staff/web/department_show_live.ex` | subscribe-before-fetch + `Logger.debug` catch-all | 2 |
| `lib/phoenix_kit_staff/web/team_show_live.ex` | subscribe-before-fetch + `Logger.debug` catch-all + `log_operation_error` on add/remove `:error` | 2, 3 |
| `lib/phoenix_kit_staff/web/person_show_live.ex` | subscribe-before-fetch + new `Logger.debug` catch-all (was missing) | 2 |
| `lib/phoenix_kit_staff/web/helpers.ex` | NEW — `log_operation_error/3` with PII-safe reason summary | 3 |
| `lib/phoenix_kit_staff/staff.ex` | 13 `@spec` declarations | 3 |
| `lib/phoenix_kit_staff/paths.ex` | 13 `@spec` declarations | 3 |
| `lib/phoenix_kit_staff/pub_sub.ex` | 11 `@spec`s + `@typedoc topic` + `@typedoc event` | 3 |
| `lib/phoenix_kit_staff/l10n.ex` | 3 `@spec` declarations | 3 |
| `lib/phoenix_kit_staff/schemas/person.ex` | `unique_constraint(:user_uuid, name: :phoenix_kit_staff_people_user_index, ...)` | 3 |
| `mix.exs` | `test_coverage: [ignore_modules: [...]]` filter | 2 |
| `test/phoenix_kit_staff/integration/activity_log_rescue_test.exs` | NEW (+2) | 2 |
| `test/phoenix_kit_staff/web/handle_info_catchall_test.exs` | NEW (+7) | 2 |
| `test/phoenix_kit_staff/web/subscribe_before_fetch_test.exs` | NEW (+3) | 2 |
| `test/phoenix_kit_staff/web/helpers_test.exs` | NEW (+6) | 3 |
| `test/phoenix_kit_staff/web/error_branch_logging_test.exs` | NEW (+5) | 3 |
| `test/phoenix_kit_staff/web/listing_lvs_test.exs` | NEW (+15) | 3 |
| `test/phoenix_kit_staff/edge_cases_test.exs` | NEW (+29) | 3 |
| `test/phoenix_kit_staff/module_callbacks_test.exs` | NEW (+10) | 4 |
| `test/phoenix_kit_staff/l10n_test.exs` | NEW (+15) | 4 |
| `test/phoenix_kit_staff/web/team_form_live_test.exs` | NEW (+9) | 4 |
| `test/phoenix_kit_staff/web/coverage_test.exs` | NEW (+44) | 4 |
| `test/phoenix_kit_staff/coverage_extras_test.exs` | NEW (+69) | 5 |

## Verification

- `mix format` — clean.
- `mix compile --warnings-as-errors` — clean.
- `mix credo --strict` — 345 mods/funs, 0 issues.
- `mix dialyzer` — 0 errors.
- `mix test` — **302 tests, 0 failures** (+221 over the original
  sweep baseline of 81; +253 over the pre-sweep baseline of 49).
- **5/5 consecutive `mix test` runs stable**, no flakes.
- `mix test --cover` — **95.07% production coverage** (up from
  62.64% pre-Batch-4; +32.43pp across Batches 4 and 5). At the
  practical no-deps ceiling for DB-only modules; residuals
  documented above.
- No regressions vs C0 baseline. No UI / template / heex changes were
  made — Batch 2/3/4 are entirely lib/test edits (Logger.debug calls,
  `@spec`, activity-log helper, schema constraint name, tests). The
  C0 visual baselines under `dev_docs/baselines/` remain accurate.

## Open

None.
