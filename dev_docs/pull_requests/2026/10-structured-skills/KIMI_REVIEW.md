# Kimi Review — PR #10 follow-up fixes

PR #10 introduced structured skills, per-skill dynamic proficiency levels,
soft-delete for people, the Comments tab, and a quality sweep. The branch was
merged to `main` and subsequently received review-fix commits. This review
covers a fresh pass over that work plus the small follow-up fixes committed
directly to `main` in response.

## Quality verification run

```bash
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
mix test
```

Results:

- Compile: clean
- Format: clean
- Credo (`--strict`): no issues
- Dialyzer: passed (2 known gettext false positives skipped via `.dialyzer_ignore.exs`)
- Tests: 103 unit tests passed; 332 integration tests auto-excluded because
  Postgres is not running in this environment (expected per `AGENTS.md`)

## Findings

### BUG - MEDIUM: `Skills.person_counts/0` included trashed people

`person_counts/0` aggregated every `person_skills` row, but the skill-show
roster (`list_people_for_skill/1`) and add-picker (`people_without_skill/1`)
already exclude trashed people. That made the Skills list view (and its
delete-confirmation text) report higher assignment counts than the roster
actually displayed.

**Fix:** inner-join `staff_person` and filter `status != "trashed"` so the
count matches the roster.

File: `lib/phoenix_kit_staff/skills.ex`
Commit: `2245c30`

### IMPROVEMENT - MEDIUM: Context functions don't guard against trashed people

`Staff.Memberships.add_team_person/2` and `Skills.assign_skill/3` will accept a
trashed `staff_person_uuid` on a direct context call. The UI pickers already
exclude trashed people (`people_not_on_team/1`, `people_without_skill/1`), so
this is only reachable via the API, but the rest of the soft-delete code is
heavily hardened against such calls. Consider returning `{:error,
:person_trashed}` from these entry points.

Not fixed in the direct commit; flagged for a follow-up if desired.

**Follow-up:** Confirmed still open in [Mistral Review](MISTRAL_REVIEW.md#new-findings).
The inconsistency remains — these are the only soft-delete write paths without
guards against trashed people.

### NITPICK: `Staff.get_person/2` spec had a meaningless `| any()` union

The spec was `UUIDv7.t() | String.t() | any()`, which collapses to `any()`.
Tightened to `UUIDv7.t() | String.t()`.

File: `lib/phoenix_kit_staff/staff.ex`
Commit: `2245c30`

### NITPICK: `PhoenixKitStaff` module doc was stale

The `@moduledoc` still described the visible subtabs as Overview,
Departments, Teams, and Members, and omitted skills. Updated to Overview,
Departments, Teams, Staff, and Skills, and added skills to the feature list.

File: `lib/phoenix_kit_staff.ex`
Commit: `2245c30`

## What was already correct

- `SkillShowLive.remove_person` **does** log `staff.person_skill_removed`
  (the existing test in `skill_show_live_test.exs` would catch a missing log).
- Soft-delete hardening (changeset rejects the trashed sentinel, permanent
  delete is trash-only, TOCTOU-safe DB-scoped delete, bulk ops, etc.) is
  comprehensive.
- Activity logging is consistent across department/team/person/skill LVs.
- The hard `phoenix_kit_comments` dependency and `PhoenixKitComments.Embed`
  integration are wired correctly.

## Test added

`test/phoenix_kit_staff/integration/skills_test.exs`
- `person_counts/0 excludes trashed people so the count matches the skill-show roster`

## Commits pushed

- `2245c30` — Fix skill person-count scoping and tidy specs/docs
