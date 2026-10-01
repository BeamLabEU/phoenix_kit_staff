# Follow-up Items for PR #21

Triaged against `main` on 2026-10-01. Findings from `CLAUDE_REVIEW.md`,
checked against the current code (including the 2026-09-30/10-01 UI
sweep commits).

## Fixed (pre-existing)

- ~~**BUG - MEDIUM** `trash_person/1` / `restore_person/1` stopped
  bumping `updated_at`~~ — fixed in the review commit `c9a44f6`. Both
  UPDATEs set `updated_at` and select it back:
  `lib/phoenix_kit_staff/staff.ex:347-355` (trash) and `:388-396`
  (restore). Pinned by `test/phoenix_kit_staff/integration/soft_delete_test.exs:24`.
- ~~**BUG - MEDIUM** Merged PR failed `mix precommit` (dialyzer
  unreachable clauses)~~ — fixed in `c9a44f6`. `PeopleLive.do_trash/2`
  (`people_live.ex:192-207`) and `do_restore/2` (`:210-225`) now match only
  `{:ok, _}` and the one specific error each function can return.
- ~~**NITPICK** Two spellings of the actor lookup~~ — fixed in `c9a44f6`.
  No `PhoenixKitWeb.Actor.uuid` call is left in `lib/`; everything goes
  through `Activity.actor_uuid/1` (`activity.ex:17`), e.g.
  `person_media_component.ex:46` and `:70`.

## Files touched

None — documentation only.

## Verification

- Read `CLAUDE_REVIEW.md` in full, including "Verified OK".
- Read the current `staff.ex`, `people_live.ex`, `person_show_live.ex`,
  `person_media_component.ex`, `attachments.ex` and `activity.ex`, plus
  core's `ResourceFolders.holds_file?/3` in the workspace's `phoenix_kit`
  checkout.
- No code was compiled or run for this triage.

## Open

Awaiting Max's decision (fix now, skip, or separate PR). The reviewer
marked these "not fixed"; all three are still live:

- **NITPICK** — `remove_file` treats "file was not in this folder" as a
  removal — `lib/phoenix_kit_staff/attachments.ex:226-229` collapses
  core's `{:ok, :absent}` into `:ok`, so
  `lib/phoenix_kit_staff/web/person_media_component.ex:100-103` still logs
  `staff.person_*_removed` and runs `maybe_clear_avatar/2`. Harmless (the
  avatar clear is conditional on the pointer).
- **NITPICK** — Avatar picker shows images that `set_avatar` will refuse —
  `lib/phoenix_kit_staff/web/person_show_live.ex:503`
  (`scope_folder_id={@avatar_folder_uuid}` browses the whole subtree)
  versus `attachments.ex:325` (`ResourceFolders.point_at/6` →
  `holds_file?/3`, which checks the `Images` folder itself only). An image
  in a sub-folder made by hand under `Images` in the media browser shows in
  the picker but fails with "Could not set the photo."
- **NITPICK** — "Profile photo removed" when none was set —
  `lib/phoenix_kit_staff/web/person_show_live.ex:225-232` with
  `attachments.ex:362-363`: with no pointer, `clear_avatar/2` returns the
  person with a `nil` avatar, so the page logs `staff.person_avatar_removed`
  and flashes success. Needs a forged event or a race (the button only
  renders when an avatar is shown).
