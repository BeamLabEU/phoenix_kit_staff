# Review — PR #3 (phoenix_kit_staff)

**PR:** [Quality sweep + re-validation: Errors, activity, async UX, error-branch audit, 95.07% coverage](https://github.com/BeamLabEU/phoenix_kit_staff/pull/3)
**Author:** Max Don (mdon)
**Date:** 2026-04-30
**State:** MERGED (9 commits, 56 files, +5440/−76)
**Reviewer:** Claude (Opus 4.7, 1M context)

## Verdict: ✅ Ship-quality (already merged) — two genuine bug fixes, several IMPROVEMENT/NITPICK items for follow-up

This is the workspace's canonical Phase 1 + Phase 2 quality sweep plus
the 2026-04-28 post-Apr re-validation pipeline (Batches 2/3/4/5). The
sweep is structural — it is not adding features, it is bringing the
module up to the standard the rest of the workspace already enforces
(see `phoenix_kit_locations#3`, `phoenix_kit_publishing#10`,
`phoenix_kit_catalogue#14`).

What I want to highlight for developers reviewing this PR shape in
the future, and what I would flag if it had not already merged.

## What changed (orientation)

| Layer | Change |
|---|---|
| `lib/phoenix_kit_staff.ex` | `enabled?/0` now also `catch :exit, _ -> false` for sandbox-shutdown safety. |
| `lib/phoenix_kit_staff/activity.ex` | Rescue widened to canonical post-Apr shape: explicit `Postgrex.Error -> :ok`, `DBConnection.OwnershipError -> :ok` clauses ahead of the generic `Logger.warning` fallback, plus `catch :exit, _ -> :ok`. |
| `lib/phoenix_kit_staff/errors.ex` | NEW — atom → translated-string dispatcher (`:blank_email`, `:placeholder_already_claimed`, `:email_already_taken`, `:not_found`, generic fallback). Context fns now return `{:error, atom}`; LVs translate at the presentation boundary. |
| `lib/phoenix_kit_staff/web/helpers.ex` | NEW — `log_operation_error/3` writes a failure-side activity row (`db_pending: true` + PII-safe reason summary). Wired into 5 destructive call sites. |
| `lib/phoenix_kit_staff/schemas/{person,team}.ex` | Schema-level constraint fixes (see "Correctness" below). |
| `lib/phoenix_kit_staff/staff.ex` | Leap-day display drift fix from PR #2 review (`anniversary_in_year/2` helper); `MapSet.new/2` micro-opt; 13 `@spec`s; `rename_placeholder_email/2` returns atoms instead of pre-translated binaries. |
| `lib/phoenix_kit_staff/web/{department,team,person}_show_live.ex` | `subscribe(...)` now runs BEFORE the DB read in `mount/3`, closing a stale-LV race window. |
| `lib/phoenix_kit_staff/web/*_live.ex` (all 7) | `handle_info/2` catch-all promoted from silent `{:noreply, socket}` to `Logger.debug(...)`. **`PersonShowLive` previously had no catch-all at all.** |
| Typespecs | `@type t` on every Ecto schema; 41 new `@spec`s across `staff.ex` / `paths.ex` / `pub_sub.ex` / `l10n.ex` / `activity.ex`. |
| `mix.exs` | `test_coverage: [ignore_modules: ...]` filter; new `test.setup` / `test.reset` aliases; `lazy_html` test-only dep for `Phoenix.LiveViewTest`. |
| `test/` | +253 tests (final count: 302/0). New test infra under `test/support/` (Endpoint / Router / Layouts / DataCase / LiveCase / Hooks / ActivityLogAssertions / sandbox migration). |

## Correctness

### BUG - HIGH (now fixed) — `Schemas.Person.changeset/2` `unique_constraint` name mismatch

`lib/phoenix_kit_staff/schemas/person.ex:111-114`. The DB index is
`phoenix_kit_staff_people_user_index`, but the changeset registered
the Ecto-default name `phoenix_kit_staff_people_user_uuid_index` (derived
from the field name passed to `unique_constraint(:user_uuid, ...)`).
Without the explicit `name:` opt, a duplicate `user_uuid` insert
would have raised `Ecto.ConstraintError` instead of returning the
expected `{:error, %Ecto.Changeset{}}` — a real production foot-gun,
since callers pattern-match on `{:error, _}`. The fix passes
`name: :phoenix_kit_staff_people_user_index` explicitly. Same shape
of bug as the team-changeset fix in commit `e003c53` of this same
PR. Pinned by the new edge-case test, which is what surfaced it.

### BUG - MEDIUM (now fixed) — `PersonShowLive.handle_info/2` had no catch-all

`lib/phoenix_kit_staff/web/person_show_live.ex` previously matched
only `{:staff, ...}`-shaped messages. Any other message reaching the
LV's mailbox (a stray `:DOWN` from a monitored process, a misrouted
PubSub event, a custom hook message) would have raised
`FunctionClauseError` and crashed the LV. The other 6 LVs had silent
`do: {:noreply, socket}` catch-alls — those got promoted to
`Logger.debug(...)`, which is purely a quality-of-life upgrade, but
adding the missing clause to `PersonShowLive` is a real fix.

### BUG - LOW (now fixed) — Subscribe-after-fetch race on the 3 show pages

`department_show_live.ex` / `team_show_live.ex` / `person_show_live.ex`
mounts now call `StaffPubSub.subscribe(...)` BEFORE the DB read. A
broadcast firing in the gap was silently dropped; the receiving LV
stayed stale until manual reload. Note that the URL `id` is the UUID,
so the topic key was already correct under both orderings — the only
change is the `connected?(socket)` subscribe sits above the `case
Departments.get/2` instead of inside the `dept ->` branch. Negligible
runtime cost for correctness.

### BUG - LOW (now fixed) — Leap-day display drift in `next_birthday_and_days/2`

Carried over from PR #2 review. The wrap-to-next-year branch always
clamped Feb 29 → Feb 28 even when the target year was a leap year.
The Postgres `INTERVAL '1 year'` filter preserves Feb 29 in leap
target years, so the displayed `days_until` was off by 1 vs the
window the SQL admitted by. Fix uses a new `anniversary_in_year/2`
helper that mirrors Postgres's behaviour. Pinned by a tightened
Feb 29 test that asserts `days_until == Date.diff(next_birthday, today)`.

### Scoping fix — `Schemas.Team.changeset/2` `unique_constraint` field

`lib/phoenix_kit_staff/schemas/team.ex:38-41`:
`unique_constraint([:department_uuid, :name], name: ...)` →
`unique_constraint(:name, name: ..., ...)`. The composite-list form
attaches the changeset error to the **first** field in the list
(`:department_uuid`), so the inline form error rendered below the
wrong input. Now it renders below `:name`, which is the field the
user actually edits. The constraint check itself is unchanged because
the index `name:` opt is explicit.

## Code quality

### IMPROVEMENT - MEDIUM — Form Save errors don't write failure-side audit rows

`Helpers.log_operation_error/3` is wired into the 5 destructive call
sites (`people/departments/teams_live#delete`,
`team_show_live#add_person/remove_person`) but is NOT wired into
form-level Save failures in `person_form_live#save :new` and
`#save :edit` (lines 152-156, 182-185 of `person_form_live.ex`). The
moduledoc on `Web.Helpers` correctly notes that `phx-change` keystroke
cycles should NOT generate audit rows, but a Save submission that
fails on `{:error, atom}` or `{:error, %Ecto.Changeset{}}` is exactly
the kind of "admin click that didn't succeed" the post-Apr pipeline
wants to capture. The same gap exists in `department_form_live` and
`team_form_live`. Consider adding `Helpers.log_operation_error` to the
form Save error branches (gate on `params["save"]`-style intent, NOT
on validate-cycle entry, to avoid spam).

### IMPROVEMENT - LOW — `Errors.message/1` fallback is silent

`lib/phoenix_kit_staff/errors.ex:55` returns the generic message for
any unknown atom. The moduledoc says "a fallback that fires in
production is a sign that a context fn returned an atom this module
doesn't know about" — but there's no `Logger.warning`, no telemetry,
no dev-time loud failure. A typo in a context fn (`:blank_emial`) silently
degrades UX to "Something went wrong. Please try again." in production
and never alerts. Consider a `Logger.warning("[Staff] Unknown error
atom: #{inspect(atom)}")` in the fallback clause (and a corresponding
`refute log =~ "Unknown error atom"` in the per-atom tests).

### IMPROVEMENT - LOW — `Helpers.log_operation_error` lets callers override `db_pending`

`web/helpers.ex:64-67`:

```elixir
base_metadata = %{"db_pending" => true} |> Map.merge(reason_metadata(reason))
metadata = base_metadata |> Map.merge(stringify_keys(extra_metadata))
```

The merge order means a caller passing `metadata: %{"db_pending" => false}`
or `metadata: %{db_pending: "yes"}` would silently break audit-feed readers
that distinguish attempted-but-failed from completed actions on this key.
Today no caller does this, but the contract is implicit. Either:

1. `Map.merge(stringify_keys(extra_metadata), base_metadata)` so
   helper-owned keys win, or
2. `Map.put_new` for the helper-owned keys after the user merge, or
3. Document the precedence explicitly in the moduledoc + add a test
   pinning the contract.

### IMPROVEMENT - LOW — `activity_logging_test.exs` does not test the LV call sites

`test/phoenix_kit_staff/integration/activity_logging_test.exs` calls
`Activity.log` directly inside each test, then asserts the row exists.
This proves the wrapper writes a row tagged with the action atom
passed in — but it does NOT prove that any LiveView ever calls
`Activity.log("staff.person_created", ...)` with that exact atom. A
typo'd action atom in `person_form_live.ex` would not regress this
test — only the `listing_lvs_test.exs` and form-LV tests catch
LV→action threading. Consider renaming this file
(`activity_log_wrapper_test.exs`?) so the contract is clearer, OR
making each test drive the LV instead of calling the wrapper directly.

### IMPROVEMENT - LOW — `coverage_extras_test.exs` is "coverage debt", not behavior tests

998 lines of tests written specifically to push coverage from 89% →
95% (Batch 5). Several use `TestRepo.query!("UPDATE ... SET status = $1
...")` to set up out-of-band states that the public API
(`validate_inclusion(:status, [active, inactive])`) explicitly
rejects, so they exist purely to fire defense-in-depth catch-all
branches. The FOLLOWUP openly acknowledges this and lists the
residuals as "deliberate defense-in-depth choices."

This is fine as a workspace-wide convention, but the cost is a 1k
line test file that future readers will mistake for behavioral tests.
Two cheaper alternatives:

1. **Drop the catch-all** in `status_badge_class/1` and let
   `validate_inclusion` be the single source of truth — then no test
   is needed because no branch exists to cover.
2. **Move coverage-only tests** into `*_coverage_test.exs` files with
   a `@moduledoc` that says "these tests exist to fire defense-in-depth
   branches that are unreachable through the public API; behavioral
   coverage lives elsewhere."

### NITPICK — `stringify_keys/1` fallback is dead code

`web/helpers.ex:69-71`: `defp stringify_keys(other), do: other`. The
only caller (`Map.merge(base_metadata, …)`) would crash on a non-map
before this clause runs. The FOLLOWUP confirms it's unreachable.
Either remove the clause and let dialyzer complain if a non-map sneaks
in, or accept it as defensive and stop trying to cover it.

### NITPICK — `reason_metadata/1` doesn't bound `error_keys` length

`web/helpers.ex:55-58`: an `Ecto.Changeset` with 50 errors lands all
50 field names into `error_keys`. Probably fine in practice (changesets
rarely have >5 errors) but worth a `Enum.take(20)` if the audit table
column is a `text` column with a soft byte budget.

## Performance

- The leap-day fix is a hot-path helper; the `case Date.new/3` shape
  is `O(1)` and runs only once per row admitted by the SQL window
  filter. No regression.
- `MapSet.new(all_memberships, & &1.staff_person_uuid)` skips the
  intermediate list. Micro-opt, correct.
- The new error-side activity logging adds one DB round-trip per
  failed mutation. Failure paths are rare and admin-only — fine.
- The `subscribe-before-fetch` reordering is free.

## Tests

**302 tests, 0 failures, 5/5 stable runs, 95.07% line coverage.**
Test infra is comprehensive: dedicated `Test.Endpoint` / `Test.Router`
/ `Test.Layouts`, on-mount hook for plugging real
`%PhoenixKit.Users.Auth.Scope{}` into the LV session, sandbox-aware
`DataCase`/`LiveCase`, and `ActivityLogAssertions` for asserting on
the activity table. Solid foundation — the rest of the workspace can
copy this pattern.

The sandbox migration approach (`test/support/postgres/migrations/...`)
inlines V100 staff DDL idempotently so `mix test` doesn't depend on
which `phoenix_kit` Hex version ships V100. Good defensive choice.

Gaps (see Code quality):
- LV→action-atom threading not pinned in `activity_logging_test.exs`
  (covered indirectly elsewhere).
- Form-level Save failures not exercised through `Helpers.log_operation_error`
  (because they aren't wired to it — see IMPROVEMENT-MEDIUM above).
- `mix test --cover` is the only coverage tool; no excoveralls / Mox /
  Bypass. Per workspace convention, fine.

## Security

- `reason_metadata/1` correctly never surfaces changeset error
  **messages** (which often interpolate user input) — only the
  field-name keys land in metadata. Test `helpers_test.exs` pins this
  with a `RuntimeError` carrying a "secret leak attempt" message and
  asserts the message string never lands in `error_keys`. Good.
- `Errors.message/1` returns only literal `gettext(...)` strings —
  no user data flows through.
- `Activity.log/2` rescues / catches everything; no error leaks back
  to the LV that could surface raw exception messages to the user.
- `enabled?/0` `rescue _ -> false` + `catch :exit, _ -> false` means
  module discovery never crashes and never accidentally enables a
  module that isn't supposed to be enabled. Fail-closed. Good.

## Process

- **PR shape:** 5440 additions / 9 commits / 56 files. The workspace's
  quality-sweep convention bundles Phase 1 + Phase 2 + Re-validation
  Batches 2-5 into a single PR. This is the canonical pattern in the
  workspace (per `BeamLabEU/phoenix_kit_locations#3` etc.) so it would
  be wrong to review it as if it should have been split. For
  consumers of this pattern: the `FOLLOWUP.md` is load-bearing — it's
  what makes a 5k-line diff legible. The next reviewer will start
  from `FOLLOWUP.md`, not the diff.
- **Head ref deviation:** PR is from `mdon:quality-sweep` instead of
  the usual `mdon:main`. The PR description documents the harness
  reason (Claude-Code permission system blocked direct pushes to
  `main`, even on the fork) and the fast-forward recipe. Good
  hygiene.
- **No version bump** — correct, this is pure quality work, not a
  releasable feature.

## Summary

| Area | Status |
|---|---|
| Bug fixes | ✅ 4 real fixes (1 HIGH, 1 MEDIUM, 2 LOW) |
| Activity wrapper | ✅ canonical rescue shape; covered |
| Error-branch audit logging | ⚠️ wired for destructive listing actions; missing for form Save failures |
| Errors dispatcher | ⚠️ no Logger.warning on unknown-atom fallback |
| Async UX (subscribe-before-fetch, handle_info catch-all) | ✅ correct |
| Typespecs | ✅ comprehensive |
| Tests | ✅ 302/0 stable; some "coverage debt" in `coverage_extras_test.exs` |
| Test infra | ✅ workspace-grade; copyable |
| Security | ✅ no concerns; PII-safe metadata |
| Performance | ✅ no regressions; one micro-opt |

**Follow-up suggested (none blocking):**

1. Wire `Helpers.log_operation_error` into form Save failures
   (`person_form_live` / `team_form_live` / `department_form_live`)
   with a guard so `phx-change` validate cycles don't fire it.
2. Add `Logger.warning(...)` to `Errors.message/1`'s `_other` fallback
   so unknown-atom drift is loud in dev/staging.
3. Decide on `Helpers.log_operation_error` metadata-merge precedence
   (helper-owned-keys-win is probably the safer default).
4. Either drop the `coverage_extras_test.exs` defense-in-depth catch-
   all tests OR rename so future readers understand they exist for
   coverage, not behavior.
5. (Already in FOLLOWUP) The `Activity` 58.33% / `PhoenixKitStaff`
   81.25% residuals are unreachable through the wrapper — leave alone.

---

## Follow-up landed in-tree (post-merge, 2026-04-30)

Items 1–3 above resolved in the working tree. (4 and 5 left as-is per
the FOLLOWUP rationale.)

| Item | Resolution | Files |
|---|---|---|
| **#1 Form Save audit rows** | Wired `Helpers.log_operation_error` into the `:new`/`:edit` Save error branches of all three form LVs. The validate cycle goes through `handle_event("validate", ...)` and never reaches `save/3`, so keystroke noise stays out of the audit feed. New audit rows carry `db_pending: true`, `error_kind` (`"changeset"` / `"atom"`), and an `attempted_*` field that captures intent without leaking PII. For failed CREATEs the row has `resource_uuid: nil`; for failed UPDATEs it carries the original record's uuid so reviewers can correlate against successful updates. | `lib/phoenix_kit_staff/web/{department,team,person}_form_live.ex` |
| **#2 Errors fallback Logger.warning** | `Errors.message/1` `_other` clause now `Logger.warning("[Staff] Errors.message/1 fallback fired for unknown atom: ...")`. Return value unchanged (still the generic gettext fallback). Pinned by a new test in `errors_test.exs` using `capture_log/2`. | `lib/phoenix_kit_staff/errors.ex` |
| **#3 Helper merge precedence** | `Helpers.log_operation_error` now merges caller-supplied metadata UNDER the helper-owned keys (`db_pending` / `error_kind` / `error_keys` / `error_atom`). A buggy caller passing `metadata: %{"db_pending" => false}` can no longer poison the audit-feed contract. Pinned by a new test in `helpers_test.exs`. Also: `:resource_uuid` opt promoted from `Keyword.fetch!` to `Keyword.get` so the helper accepts failed-CREATE call sites that have no uuid yet. Moduledoc updated to reflect the new precedence. | `lib/phoenix_kit_staff/web/helpers.ex` |
| **#bonus test_helper portability** | `test_helper.exs` rescues `ErlangError` from `System.cmd("psql", ...)` so `mix test --exclude integration` works in environments without `psql` on PATH (CI, minimal containers). Connection-attempt path unchanged; integration tests still excluded when DB is unreachable. | `test/test_helper.exs` |

### New tests pinning the contracts

- `test/phoenix_kit_staff/errors_test.exs` (+1 case, +1 dedicated pin) — `capture_log` pins the unknown-atom warning fires with the action-relevant detail in the message body.
- `test/phoenix_kit_staff/web/helpers_test.exs` (+2 cases) — helper-owned keys win over caller-supplied collisions; failed CREATE without `:resource_uuid` still lands an audit row.
- `test/phoenix_kit_staff/web/department_form_live_test.exs` (+2 cases) — create + edit Save errors land `db_pending: true` rows with the right resource_uuid shape.
- `test/phoenix_kit_staff/web/team_form_live_test.exs` (+2 cases) — same shape.
- `test/phoenix_kit_staff/web/person_form_live_test.exs` (+3 cases) — atom branch (`:blank_email`), changeset branch (invalid status), and edit branch all pinned.

### Verification

- `mix compile --warnings-as-errors` — clean.
- `mix format --check-formatted` — clean across all 11 touched files.
- `mix credo --strict` (on the 5 production files edited) — 0 issues.
- `mix test --exclude integration` — 6/6 unit tests pass (the new
  errors_test cases included). Integration / LiveCase tests require a
  reachable PostgreSQL and were not run in this environment; the user
  should re-run the full suite via `mix test` from `/www/app` per the
  workspace's documented precommit chain.
