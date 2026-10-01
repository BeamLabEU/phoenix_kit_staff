# Follow-up Items for PR #20

Triaged against `main` on 2026-10-01. Findings from `CLAUDE_REVIEW.md`,
checked against the current code. Note: PR #21 later moved person media
onto core's `Storage.ResourceFolders` and shrank `MediaReorganizer` to a
core `ResourceSource` spec, so the fixes below now live in core and
staff only calls them.

## Fixed (pre-existing)

- ~~**BUG - MEDIUM** `Attachments` resolved trashed folders while the
  reorganizer only saw live ones~~ — fixed in the review commit `990203b`
  (`is_nil(f.trashed_at)` in staff's lookups). Today
  `attachments.ex:141-143` calls `ResourceFolders.find_named/3` (and
  `:81` `find_under/2`), and core's lookups filter `is_nil(f.trashed_at)`
  (`phoenix_kit` `lib/modules/storage/resource_folders.ex:286`, `:317`).
  `purge_person_media/1` (`attachments.ex:247-248`) goes through
  `ResourceFolders.purge_named/1`.
- ~~**IMPROVEMENT - MEDIUM** Runtime hook answer not normalised like the
  plan's~~ — fixed in `990203b` (`normalize_parent/2`). Today
  `attachments.ex:127-128` delegates to `ResourceFolders.parent_uuid/4`,
  whose `parent_answer/1` casts the answer with `Ecto.UUID.cast/1`
  (downcases) and turns a non-uuid into an error that is logged and falls
  back to the media root (core `resource_folders.ex:103-119`, `:235-240`).
  Plan and runtime now share the same core code.
- ~~**NITPICK** Stale "core does not ship the engine yet" comments~~ —
  fixed in `990203b`, and the module has since been rewritten:
  `lib/phoenix_kit_staff/media_reorganizer.ex` no longer carries that
  comment, and `lib/phoenix_kit_staff.ex:91` registers
  `media_reorganizer/0` with a plain `@impl PhoenixKit.Module`.

## Files touched

None — documentation only.

## Verification

- Read `CLAUDE_REVIEW.md` in full, including "Not changed".
- Read the current `attachments.ex`, `media_reorganizer.ex` and
  `phoenix_kit_staff.ex`, and the core functions they now call in the
  workspace's `phoenix_kit` checkout (`ResourceFolders.parent_uuid/4`,
  `parent_answer/1`, `find_named_all/3`, `cast/1`).
- No code was compiled or run for this triage.

## Open

Awaiting Max's decision (fix now, skip, or separate PR). Both are
reviewer observations recorded under "Not changed"; the reviewer proposed
no change, but nothing has altered them since:

- **LOW** — A legacy folder under some other parent is resolved at runtime
  but never moved by the reorganizer —
  `lib/phoenix_kit_staff/attachments.ex:141-143` (`find_named(...,
  anywhere: true)`, core rank 2) versus the plan, which reports it as
  `:relocated` and leaves it. The UI keeps working; the reviewer judged this
  to match the Source contract for modules that store no folder pointer.
- **LOW** — The plan loads every non-trashed person to build its candidate
  list — `lib/phoenix_kit_staff/media_reorganizer.ex:20-36` (now run by
  core's `ResourceSource.plan/3`). One query plus one `name = ANY($1)`
  lookup; the reviewer judged it fine at staff scale.
