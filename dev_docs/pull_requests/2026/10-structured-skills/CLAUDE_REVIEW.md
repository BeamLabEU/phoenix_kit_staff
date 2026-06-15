# Claude Review — PR #10

PR: **Structured skills + per-skill dynamic proficiency levels + quality sweep (#10)**  
Merged commit: `75dbaf8`  
Review-fix commit: `964d320` (Co-Authored-By: Claude Opus 4.8)

This review documents the findings from the post-merge review of PR #10 that
were applied in commit `964d320`.

---

## BUG - HIGH: Packaging regression lost from prior review work

**Finding:** `mix.exs` had lost several packaging/quality settings during the
PR #10 branch work:

- `priv` was missing from `package/0` `files`, so a published Hex build would
  not ship the `priv/gettext` catalogs.
- `.dialyzer_ignore.exs` existed but was not wired into `dialyzer:`
  `ignore_warnings`, making the ignore file a no-op.
- The `hex.audit` precommit step was missing from the `precommit` alias.

**Fix:** Restored in `mix.exs`; bumped version to `0.5.0`; restored the
`CHANGELOG.md` entries for `0.4.0` (i18n) and added `0.5.0` (skills /
soft-delete / comments).

**File:** `mix.exs`, `lib/phoenix_kit_staff.ex`, `CHANGELOG.md`

---

## BUG - HIGH: Org-tree roster sort could crash on staff without an email

**Finding:** In `Staff.Org.org_tree/0`, team rosters were sorted by
`p.user && p.user.email`. When a linked user had no email, the sort key was
`nil`, and `Enum.sort_by/2` raises because it cannot compare `nil` with
binary strings.

**Fix:** Normalize the sort key to `""` when email is absent:

```elixir
Enum.sort_by(fn p -> (p.user && p.user.email) || "" end)
```

**File:** `lib/phoenix_kit_staff/staff/org.ex`

---

## IMPROVEMENT - HIGH: `PeopleLive` ran the list query twice per soft-delete action

**Finding:** Every soft-delete/trash/restore/permanent-delete handler called
`load_people/1` directly, but each mutation also broadcasts on
`topic_people()`. Because broadcasts are delivered to the same process, the
`handle_info({:staff, ...}, ...)` clause then reloaded the list a second time.

**Fix:** Removed the redundant `load_people/1` calls from all mutation
handlers and documented in the `handle_info` clause that reloads happen via
the broadcast.

**File:** `lib/phoenix_kit_staff/web/people_live.ex`

---

## IMPROVEMENT - MEDIUM: Search input in people list was not debounced

**Finding:** The staff-list search `<.input>` fired a `phx-change="filter"`
event on every keystroke without debouncing, causing repeated list queries.

**Fix:** Added `phx-debounce="300"` to the search input.

**File:** `lib/phoenix_kit_staff/web/people_live.ex`

---

## BUG - MEDIUM: `PersonFormLive` silently swallowed skill-sync errors

**Finding:** `sync_skills/2` and its helpers used `with {:ok, _} <- ... do`
clauses. If `Skills.unassign_skill/1`, `assign_with_fallback/3`, or
`update_with_fallback/3` returned an error, the activity row was simply not
logged and no diagnostics were emitted — making concurrent-skill-edit races
or DB issues invisible.

**Fix:** Replaced the `with` clauses with `case` branches that log a
`Logger.warning` containing the skill/person UUID and the failure reason.

**File:** `lib/phoenix_kit_staff/web/person_form_live.ex`

---

## NITPICK: Stale comment about staged skills in person form

**Finding:** A comment claimed staged skills were POSTed as hidden inputs,
but they actually live in `@staged_skills` assigns and are reconciled
post-save.

**Fix:** Updated the comment to match the implemented behavior.

**File:** `lib/phoenix_kit_staff/web/person_form_live.ex`

---

## Summary

All findings above were addressed in commit `964d320`. The review also
confirmed that the larger PR #10 work — structured skills, dynamic
proficiency levels, soft-delete hardening, and the Comments tab — was
architecturally sound and only needed the cleanup items listed here.
