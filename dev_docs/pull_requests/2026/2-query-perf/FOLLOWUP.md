# Follow-up — PR #2 (query perf) review items

**Date:** 2026-04-27
**Reviewer artifact:** `REVIEW.md` (Claude Opus 4.7)

Phase 1 triage of the Claude review on the PR #2 perf change
(`upcoming_birthdays/0` SQL push-down + `org_tree/0` query consolidation,
merged as `000914f`). Findings re-verified against current `main`
(`a72268d`).

## Fixed (Batch 1 — 2026-04-27)

### BUG - LOW — leap-day display drift between SQL filter and Elixir helper

`lib/phoenix_kit_staff/staff.ex:290-305` — `next_birthday_and_days/2`
unconditionally clamped `Feb 29 → Feb 28` whenever it had to construct a
date for a different year, even when the target year *is* a leap year.
The SQL filter (`INTERVAL '1 year'` arithmetic) preserves Feb 29 in leap
target years (e.g. `2000-02-29 + 28y = 2028-02-29`), so for a Feb 29 DOB
displayed in a year where `today.year + 1` is a leap year, `next_birthday`
showed Feb 28 and `days_until` was off by 1 against what the SQL window
filter computed. Row was admitted by SQL; Elixir display was wrong.

Fix factors out an `anniversary_in_year/2` helper that mirrors Postgres's
behaviour: tries `Date.new/3` first, falls back to Feb 28 only when the
target year is non-leap (`Date.new/3` returns `{:error, _}` for Feb 29
in a non-leap year). The clamp is no longer unconditional.

### Feb 29 test tightened — pins SQL/Elixir consistency

`test/phoenix_kit_staff/integration/staff_queries_test.exs:78-99` — the
existing test asserted only `days_until >= 0 and <= 366`, which would
have passed against the buggy helper. Tightened to assert:

- `result.days_until == Date.diff(result.next_birthday, today)` —
  rules out off-by-one between SQL and Elixir.
- `result.next_birthday.day == 29` when `target_year` is a leap year,
  `28` otherwise — pins the leap-aware fall-through.

Renamed the test from "handles Feb 29 DOB without crashing (Postgres
normalizes to Feb 28 in non-leap years)" to "handles Feb 29 DOB
consistently between SQL filter and Elixir display" so the intent reads
correctly.

### NITPICK — `MapSet.new` micro-optimisation in `org_tree/0`

`lib/phoenix_kit_staff/staff.ex:327` — collapsed
`Enum.map(..., & &1.staff_person_uuid) |> MapSet.new()` to
`MapSet.new(all_memberships, & &1.staff_person_uuid)`. Skips the
intermediate list. Reviewer-flagged as cosmetic; landed alongside the
real fix.

## Fixed (test-infra prerequisites landed early)

Two test-infra items landed in Phase 1 because they blocked
verification of every other fix. Both are technically Phase 2 C7
work; doing them now means the rest of the sweep can run `mix test`
without the temp path-dep dance.

### Hammer rate-limiter ETS Backend started

`test/test_helper.exs` now starts
`PhoenixKit.Users.RateLimiter.Backend` alongside
`PhoenixKit.PubSub.Manager`. Without it,
`Staff.register_placeholder/1` (which flows through
`PhoenixKit.Users.Auth.register_user/2` → Hammer ETS) raises
`ArgumentError: the table identifier does not refer to an existing ETS
table` on every integration test that creates a person — so 17/17 of
the existing `staff_queries_test.exs` cases were failing on `main`
before the dep-version blocker even surfaced. Mirrors core's
`phoenix_kit/test/test_helper.exs:69`.

### Local test migration replacing `PhoenixKit.Migrations.up()`-from-test_helper

The original `test_helper.exs` defined
`PhoenixKitStaff.Test.SetupMigration` inline and called
`Ecto.Migrator.up(TestRepo, 1, ..., log: false)` on it. That migration
delegated to `PhoenixKit.Migrations.up()` which only knows about
the V's bundled inside the resolved `phoenix_kit` package. Hex
`phoenix_kit 1.7.95` reaches V96 today; staff's V100 hasn't been
published yet — so on a fresh `phoenix_kit_staff_test` DB the
migration created V01..V96 tables but stopped short of the staff
tables, breaking 17/17 integration tests at table-create time.

Switched to the workspace-standard pattern (locations / hello_world /
catalogue): every feature module ships its own
`test/support/postgres/migrations/<timestamp>_setup_phoenix_kit.exs`
that builds exactly the schema the module needs:

- New `test/support/postgres/migrations/20260427000000_setup_phoenix_kit.exs`
  — calls `PhoenixKit.Migrations.up()` for V01..V96 prereqs, then
  inlines the V100 staff DDL verbatim from
  `phoenix_kit/lib/phoenix_kit/migrations/postgres/v100.ex` (wrapped
  in `IF NOT EXISTS` so once core publishes V100, the inline block
  becomes a no-op).
- `config/test.exs` — repo config gains `priv: "test/support/postgres"`.
- `mix.exs` — adds `test.setup` / `test.reset` aliases and a `cli`
  block with `preferred_envs:` so they run under `MIX_ENV=test`
  without an explicit env prefix.
- `test_helper.exs` — drastically simplified: starts Repo + sandbox,
  removes the inline migration-dispatch block. First-time setup is
  now `createdb phoenix_kit_staff_test && mix test.setup` once;
  subsequent `mix test` just runs.

After this change, `mix test` runs cleanly against the Hex
`phoenix_kit ~> 1.7` dep — no temp `path:` override required. Same
pattern applied to `phoenix_kit_projects` in this batch.

## Skipped (with rationale)

### NITPICK — 7-bind heredoc fragment is verbose

`staff.ex:264-279` — `p.date_of_birth` appears six times and the CASE
recomputes the same expression in both branches. Reviewer suggested a
macro wrapper or CTE but explicitly noted: "given this file is already
~440 lines and the follow-up doc flags a future split, leaving it is
reasonable." Same trade-off applies here — the verbosity is isolated
to one query and refactoring it is appropriate work for the Phase 2
file split (when `staff.ex` actually grows past the threshold), not
this PR.

### Observation — `list_people()` wholesale fetch in `org_tree/0`

`staff.ex:318` — fetched once and iterated per department for
`dept_only_people`. Reviewer marked as "Fine at current scale; worth
noting as the org grows." Real fix would add a department-scoped
list to the Departments context; out of scope for query-perf review
follow-up.

## Resolved (2026-06-15)

### ~~BLOCKER — Hex dep version mismatch prevents test verification~~ — RESOLVED

The 2026-04-27 blocker (staff's Hex `phoenix_kit ~> 1.7` pin only reached
V96, so the V100 staff tables never got created on the test DB) is gone.
The workspace adopted resolution paths **#2 + #3**: `pk_dep/3` in `mix.exs`
swaps the Hex pin for a local `path:` + `override: true` checkout when
`PHOENIX_KIT_PATH` is set (and `phoenix_kit_parent` carries the permanent
path deps). Tests now run against local core via
`PHOENIX_KIT_PATH=../phoenix_kit mix test`.

The temporary test-infra described under "Fixed (test-infra prerequisites
landed early)" above — the inline-V100-DDL `test/support/postgres/migrations/`
file — was itself **subsequently superseded**: `test_helper.exs` now builds
the schema via `PhoenixKit.Migration.ensure_current/2` (no module-owned DDL),
which auto-applies every newly-shipped `Vxxx` (incl. the later V131 metadata
and V135 skills migrations). See the module `AGENTS.md` Testing section.

The PR #2 perf fixes themselves remain live and verified on current code:
`upcoming_birthdays/1` still pushes the day-window filter into Postgres
(`staff.ex` `fragment`), `org_tree/0` still does the single-query
`group_by`, and both are covered green by `staff_queries_test.exs` within
the full suite (432 tests, 0 failures as of 2026-06-15).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_staff/staff.ex` | leap-day fix in `next_birthday_and_days/2`; new `anniversary_in_year/2` helper; `MapSet.new` micro-opt in `org_tree/0` |
| `test/phoenix_kit_staff/integration/staff_queries_test.exs` | Feb 29 test tightened with consistency + leap-year-aware assertions |
| `test/test_helper.exs` | start `PhoenixKit.Users.RateLimiter.Backend`; remove inline `SetupMigration` + `Ecto.Migrator.up` dispatch (replaced by the proper migration file below) |
| `test/support/postgres/migrations/20260427000000_setup_phoenix_kit.exs` | NEW — calls `PhoenixKit.Migrations.up()` for V01..V96 prereqs + inlines V100 staff DDL verbatim |
| `config/test.exs` | add `priv: "test/support/postgres"` to repo config |
| `mix.exs` | add `cli/0` with `preferred_envs:` for `test.setup`/`test.reset`; add `test.setup`/`test.reset` aliases |

## Verification

- `mix format` — clean.
- `mix compile --warnings-as-errors` — clean.
- **`mix test` against the Hex `phoenix_kit ~> 1.7` dep (no path override)** —
  **49 tests, 1 failure**. The 17 `staff_queries_test.exs` cases all
  pass green, including the new tightened Feb 29 assertion. The 1
  failure is pre-existing
  (`test/phoenix_kit_staff/integration/teams_test.exs:64`,
  case-insensitive unique-name test asserts errors on `:name` but the
  changeset reports them on `:department_uuid` — constraint-name
  mapping issue). Confirmed pre-existing by stashing my edits and
  re-running against `main` `a72268d`. Independent of this PR's
  fixes; flagging as a Phase 2 item rather than expanding scope here.
- Code-level review of the leap-day fix:
  - `anniversary_in_year(dob = ~D[2000-02-29], year = 2027)` →
    `Date.new(2027, 2, 29)` → `{:error, :invalid_date}` → `Date.new!(2027, 2, 28)` ✓
  - `anniversary_in_year(dob = ~D[2000-02-29], year = 2028)` →
    `Date.new(2028, 2, 29)` → `{:ok, ~D[2028-02-29]}` ✓
  - Matches Postgres `('2000-02-29'::date + 27 * interval '1 year')::date = '2027-02-28'`
    and `('2000-02-29'::date + 28 * interval '1 year')::date = '2028-02-29'`.

## Open

None. The pre-existing `teams_test.exs:64` constraint-name mapping
failure flagged here was resolved in the PR #3 quality sweep
(`unique_constraint` name mapping) — the full suite is green (432
tests, 0 failures, 2026-06-15).
