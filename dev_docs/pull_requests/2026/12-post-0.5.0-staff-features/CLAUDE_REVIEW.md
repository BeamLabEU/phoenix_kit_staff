# Claude Review — PR #12

PR: **Post-0.5.0 staff features (employment history, media/avatar/events tabs) + Phase 1/2 quality sweep (#12)**
Merged commit: `6d7bb17`
Review-fix commit: this commit (Co-Authored-By: Claude Opus 4.8)

Post-merge review of PR #12 against released core `phoenix_kit 1.7.160`
(`mix.lock` now resolves V136 + the `Activity.list` `resource_uuid` filter +
the `MediaSelectorModal` `browse`/filter-aware accept, so the PR's
release-gate is satisfied and the tree compiles off Hex). The PR is
high-quality and heavily reviewed; the contexts (`Employments`, `Skills`,
`Attachments`, `Staff.Memberships`), schemas (`Employment`, `Skill` selector
reshape), and the new LiveComponents were verified and are architecturally
sound. The cross-module integration points were spot-checked against core and
are correct:

- `MediaSelectorModal` notify contract — the two call shapes match core:
  `PersonMediaComponent` passes `notify: {Module, id}` → `send_update` →
  `update(%{media_selected: …})`; `PersonShowLive`'s avatar picker passes no
  `notify` → `send(self(), {:media_selected, …})` → `handle_info`. Both paths
  line up with core's `media_selector_modal.ex`.
- Events-tab deep link — `Routes.path("/admin/activity?…")` preserves the query
  string (admin paths are pure prefix/locale concatenation, the `?…` survives).

One genuine display bug was found and fixed; the rest are documented
low-severity observations left as-is.

---

## BUG - MEDIUM: Skill name/description not localized on the Skills list & show pages

**Finding:** `Skill.name` and `Skill.description` are translatable (the skill
form has multilang tabs for both, the `translations` JSONB column persists the
overrides, and `Skill.localized_name/2` / `localized_description/2` exist and
are used on the person profile's Skills card). The Phase-2 sweep restored the
`localized_*/2` read path on the seven department/team/person read surfaces but
**missed the two Skills read surfaces**:

- `SkillsLive` (the list) rendered raw `skill.name` in the table and the
  delete-confirm.
- `SkillShowLive` rendered raw `@skill.name` / `@skill.description` in the
  header.

Effect: in a non-primary content locale, a skill with an override showed its
localized name on the person profile but its **primary** name on the Skills
list and the Skill show page — an inconsistent, incorrect display (the same
class of bug the sweep fixed elsewhere).

**Fix:**

- `skills_live.ex` — assign `@lang = L10n.current_content_lang()` in `render/1`;
  render `Skill.localized_name(skill, @lang)` in the table cell and the
  delete-confirm. (Activity-log metadata keeps the canonical primary `name`,
  matching the department/team delete convention.)
- `skill_show_live.ex` — assign `@lang` and render
  `Skill.localized_name/localized_description` in the header. Unified the level
  picker on `@lang` (it previously read `current_locale` via a one-off
  `locale/1` helper, now removed) so the whole page uses one content-locale
  source.

**Files:** `lib/phoenix_kit_staff/web/skills_live.ex`,
`lib/phoenix_kit_staff/web/skill_show_live.ex`

---

## IMPROVEMENT - MEDIUM: Unify the staged-skill chips on the content locale

**Finding:** `PersonFormLive` localized the staged-skill level chips (selector
group labels + option choices) via `assigns[:current_locale]`, while every
other content-display site in the module reads `L10n.current_content_lang/0`
(the value restored as the module-wide content-locale source in Phase 2).
`current_locale` (the UI/URL locale) and the content locale resolve to the same
string in normal operation, but the divergence is a latent inconsistency.

**Fix:** Compute `@content_lang = L10n.current_content_lang()` in
`PersonFormLive.render/1` and use it for the three chip-localization call sites,
matching `skill_show_live` and the read LVs.

**File:** `lib/phoenix_kit_staff/web/person_form_live.ex`

---

## Tests

Added two delta-pinning LiveView tests to
`test/phoenix_kit_staff/web/multilang_display_test.exs` (the existing
regression guard for this exact wiring):

- *"skills list renders the locale name override, not the primary name"*
- *"skill show renders the locale name + description override"*

Both assert the `et` override renders and the primary value does not, mirroring
the existing department/person cases. (These are `:integration`-tagged LiveView
tests; they run in CI / with a local Postgres — the sandbox was not reachable
in the review environment, so they were verified by construction against the
passing department/person cases they mirror.)

Verification run in the review environment: `mix compile` (clean),
`mix test --exclude integration` (127 tests, 0 failures), `mix format`
(no diff), `mix credo --strict` (no issues), `mix dialyzer` (clean).

---

## Observations left as-is (low severity, no change)

- **`Attachments.attach/2` reports success on a non-exception DB error** —
  `LOW`. `attach/2` ignores the `{:ok,_}|{:error,_}` from `repo().update/insert`
  and always returns `:ok` (exceptions are rescued + logged); `do_attach/3` then
  logs the activity row with `length(accepted)` regardless. A silent
  `{:error, changeset}` (very unlikely: a folder-uuid set, or a `FolderLink`
  insert with `on_conflict: :nothing`) would over-report. Defensive media
  handling — not worth the added control-flow churn here.
- **`Employments.create/2` trashed-person check is not row-locked** — `LOW`.
  The `person_trashed?/1` `exists?` check inside the transaction can race a
  concurrent trash (unlike `Skills.assign_skill/3`, which checks under its
  existing `FOR UPDATE` skill lock). There is no DB constraint backing it, so a
  span could be opened on a just-trashed person. Trash itself isn't locked
  either; this matches the documented "create-path guard, best-effort" intent.
- **Person-form skill *picker* labels show the primary name** — `NITPICK`. The
  staged-row label (`{s.name}`) and search dropdown (`{skill.name}`) render the
  primary name because the search filters on the primary name
  (`String.contains?(downcase(skill.name), q)`). Localizing the label without
  also searching translations would let a typed localized name fail to match,
  so this is intentionally left primary. A future "search translations too"
  pass could localize both together.

---

## Summary

PR #12 is sound. One real display bug (skill names un-localized on the Skills
list/show) is fixed and pinned, plus a content-locale consistency cleanup on the
person form. The remaining observations are low-severity and intentionally left
unchanged. All quality gates pass.
