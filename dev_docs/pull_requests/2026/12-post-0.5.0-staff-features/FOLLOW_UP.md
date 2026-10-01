# Follow-up Items for PR #12

Triaged against `main` on 2026-10-01. Findings from `CLAUDE_REVIEW.md`,
checked against the current code (including the 2026-09-30/10-01 UI
sweep commits).

## Fixed (pre-existing)

- ~~**BUG - MEDIUM** Skill name/description not localized on the Skills
  list and show pages~~ — fixed in the review commit `7c9828a`. Still in
  place: `skills_live.ex:75` assigns `@lang` from
  `L10n.current_content_lang/0` and renders `Skill.localized_name/2` in the
  table (`:115`) and the delete confirm (`:141`); `skill_show_live.ex:53-54`
  puts `localized_name/2` / `localized_description/2` in the header (now via
  the core header trail rather than an inline header). Pinned by
  `test/phoenix_kit_staff/web/multilang_display_test.exs:66` and `:78`.
- ~~**IMPROVEMENT - MEDIUM** Staged-skill chips read `current_locale`
  instead of the content locale~~ — fixed in `7c9828a`.
  `person_form_live.ex:669` assigns `@content_lang` from
  `L10n.current_content_lang/0`; the chip call sites at `:923`, `:926` and
  `:930` use it.

## Files touched

None — documentation only.

## Verification

- Read every finding and the three "observations left as-is" in
  `CLAUDE_REVIEW.md`.
- Grepped and read the current `skills_live.ex`, `skill_show_live.ex`,
  `person_form_live.ex`, `attachments.ex`, `person_media_component.ex`,
  `employments.ex` and `skills.ex`.
- Confirmed the two pinning tests still exist. No code was compiled or run
  for this triage.

## Open

Awaiting Max's decision (fix now, skip, or separate PR) — the reviewer
left these as-is; they are still live in the current code:

- **LOW** — `Attachments.attach/2` still reports success when the attach
  fails — `lib/phoenix_kit_staff/attachments.ex:204-216`. It now goes
  through core's `ResourceFolders.attach/2` and logs a warning on
  `{:error, _}`, but still returns `:ok`, so
  `person_media_component.ex:180-184` logs the "added" activity row with
  `length(accepted)` even for files that were not attached (over-reporting).
- **LOW** — `Employments.create/2` checks "person is trashed" without a row
  lock — `lib/phoenix_kit_staff/employments.ex:82` (check at `:162-166`).
  A concurrent trash can slip between the `exists?` check and the insert,
  so a span can be opened on a just-trashed person. `Skills.assign_skill/3`
  checks under a `FOR UPDATE` lock; this path does not.
- **NITPICK** — Person-form skill picker shows the primary skill name, not
  the localized one — `lib/phoenix_kit_staff/web/person_form_live.ex:901`
  (staged row) and `:988` (search dropdown); the search at `:522` matches
  only the primary name. The reviewer's note: localizing the label without
  also searching translations would make a typed localized name fail to
  match, so both would need to change together.
