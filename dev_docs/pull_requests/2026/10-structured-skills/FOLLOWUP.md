# Follow-up — PR #10 (Structured skills + per-skill dynamic proficiency levels)

After-action triage of the two review docs in this folder
(`CLAUDE_REVIEW.md`, `KIMI_REVIEW.md`). Every finding is resolved; see the
disposition column for where.

## CLAUDE_REVIEW.md

All six findings were applied by the boss in review-fix commit `964d320`
(verified against current code):

| Finding | Severity | Disposition |
|---|---|---|
| Packaging regression (`priv`, dialyzer ignore, `hex.audit`) | BUG-HIGH | Fixed in `964d320` |
| Org-tree roster sort crashes on email-less staff | BUG-HIGH | Fixed in `964d320` (`(p.user && p.user.email) \|\| ""`) |
| `PeopleLive` ran the list query twice per mutation | IMPROVEMENT-HIGH | Fixed in `964d320` (reload via broadcast only) |
| Search input not debounced | IMPROVEMENT-MEDIUM | Fixed in `964d320` (`phx-debounce="300"`) |
| `PersonFormLive` swallowed skill-sync errors | BUG-MEDIUM | Fixed in `964d320` (`case` + `Logger.warning`) |
| Stale staged-skills comment | NITPICK | Fixed in `964d320` |

## KIMI_REVIEW.md

| Finding | Severity | Disposition |
|---|---|---|
| `Skills.person_counts/0` counted trashed people | BUG-MEDIUM | Fixed in `2245c30` (inner-join `staff_person`, filter `status != "trashed"`) |
| `Staff.get_person/2` spec had a meaningless `\| any()` | NITPICK | Fixed in `2245c30` |
| `PhoenixKitStaff` moduledoc was stale (omitted Skills) | NITPICK | Fixed in `2245c30` |
| **Context create-paths don't guard against trashed people** | IMPROVEMENT-MEDIUM | **Fixed in this Phase 1 commit** (see below) |

### Context create-paths trashed-person guard (Kimi's one open item)

Kimi flagged that `Skills.assign_skill/3` and `Staff.Memberships.add_team_person/2`
accepted a trashed `staff_person_uuid` on a direct context call ("flagged for a
follow-up if desired"). The UI pickers (`people_without_skill/1`,
`people_not_on_team/1`) already exclude trashed people, so this was only
reachable via the direct API — but the rest of the soft-delete code is heavily
hardened against such calls, so the two create-paths were the gap.

**Fix.** Both now return `{:error, :person_trashed}` for a trashed person:

- `Skills.assign_skill/3` — checks inside the existing `FOR UPDATE` transaction
  (rolls back before the insert), so it can't race a concurrent trash.
- `Staff.Memberships.add_team_person/2` — guards before the insert.
- Shared private `person_trashed?/1` (a scoped `repo().exists?/1`) in each
  module; specs and docstrings updated.

**Scope rationale.** These two are the *complete* set of "attach a person by
raw uuid" create-paths. The update/remove paths are deliberately **not**
guarded — `update_assignment_levels/2`, `unassign_skill/2`, and
`remove_team_person/2` legitimately operate on a trashed person's surviving
assignment/membership rows (the soft-delete design keeps those rows so Restore
brings the person back intact).

**Tests.** `integration/soft_delete_test.exs` →
`describe "context create-paths reject a trashed person (direct-API guard)"`:
both paths return `{:error, :person_trashed}` and insert no row (asserted via
the person-keyed, non-trashed-filtering `list_skills_for_person/1` /
`list_memberships_for_person/1`).

**Verification.** `mix compile --warnings-as-errors`, `mix format --check-formatted`,
`mix credo --strict` (no issues), `mix dialyzer` (passed; 2 known gettext skips),
`mix test` — **437 tests, 0 failures** (against released core `phoenix_kit`
1.7.152, no `PHOENIX_KIT_PATH`).

## Open

None.
