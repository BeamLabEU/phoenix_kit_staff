# Claude Review — PR #20 "Media reorganizer source: plan legacy folder moves from the attachment hooks"

**Merge commit:** 8f88460
**Author:** Timujeen (timujinne/feat/media-reorganizer)
**Files:** `lib/phoenix_kit_staff.ex`, `lib/phoenix_kit_staff/media_reorganizer.ex`, `test/phoenix_kit_staff/media_reorganizer_test.exs`

## Summary of the change

Adds `PhoenixKitStaff.MediaReorganizer.plan/2`, staff's plan source for core's
`Storage.Reorganizer` engine, registered through `PhoenixKitStaff.media_reorganizer/0`.
It plans `:move`s of each live person's `staff-person-<uuid>` folder to the parent the
`:attachments_parent_folder` hook answers, and `:report`s duplicates, relocated copies,
hook errors, `nil`-root answers and orphaned folders of missing/trashed people.

Checked against core 2.24.0 (now locked), which ships `Reorganizer.Source` and
`Reorganizer.Action`: every emitted map uses only known `Action` keys, `label` is always
a string, `on_conflict: :report` (pointer-less module), `counts` are measured over every
file/link row regardless of status, all by-name lookups filter `trashed_at IS NULL`, the
hook is called only for candidates, and query count is independent of record count. Five
review rounds already landed on the branch; the plan side holds up. The findings are about
the runtime `Attachments` resolver the plan is supposed to agree with.

## Findings

### 1. BUG - MEDIUM — `Attachments` resolves trashed folders; the reorganizer only sees live ones

`find_root_folder/2` and `get_folder/2` did not filter `trashed_at`. The
`[:name, :parent_uuid]` unique index is partial (`WHERE trashed_at IS NULL`), so a trashed
`staff-person-<uuid>` can sit next to a live one. The reorganizer (correctly) ignores the
trashed one and will happily move the live folder under a parent holding a trashed twin.
The runtime resolver then ranks both at 0 and breaks the tie by `asc: uuid`; the trashed
folder is older, so it wins: the Files/Images tabs list the trashed folder and new uploads
land in it, while the live, just-moved folder is unreachable from the UI. The same happens
without the reorganizer when an admin trashes a person's folder in `/admin/media`: staff
keeps uploading into the trash.

**Fixed:** both lookups filter `is_nil(f.trashed_at)`. `purge_person_media/1` still removes
every folder with the name, trashed included. Test: "a trashed folder is never resolved,
even when it is the older twin".

### 2. IMPROVEMENT - MEDIUM — Runtime hook answer is not normalised like the plan's

The Source contract says the plan's desired parent comes from "the same functions the
module uses when it creates a folder". The plan casts and downcases the hook answer
(`{:ok, "ABC…"}` works, `{:ok, "x"}` is a `:hook_error`), but
`Attachments.parent_folder_uuid/3` passed any binary through:

- an upper-cased uuid missed `root_rank/2`'s string match, so a root twin (rank 1) beat
  the folder under the configured parent, while the plan considered the parented folder
  current — plan and UI disagreed on which folder is the person's;
- a non-uuid string reached `Storage.create_folder/1` and every first upload failed with
  `:folder_unavailable`.

**Fixed:** `normalize_parent/2` casts + downcases; a non-uuid answer logs a warning and
falls back to root, like a hook that raises (the runtime keeps "upload still works" over
the plan's "skip the record"). Tests: "a hook answer is cast and downcased; a non-uuid
answer falls back to root", "an upper-cased hook answer still prefers the folder under the
parent over a root twin".

### 3. NITPICK — Stale "core does not ship the engine yet" comments

`MediaReorganizer`'s moduledoc and the `media_reorganizer/0` comment said hex core 2.23.x
lacks the engine and that adding `@behaviour`/`@impl` was the only follow-up. Core 2.24.0
ships it and is locked here. `@behaviour`/`@impl` are still deliberately left off: the
`~> 2.0` pin (enforced by `core_pin_conformance_test.exs`) admits pre-2.24 cores, where an
undefined behaviour / unknown callback would warn in hosts.

**Fixed:** comments rewritten to state that reason.

## Not changed

- The reorganizer only adopts a legacy folder at root or under the resolved parent, while
  `Attachments` also resolves one "under any other parent" (rank 2). The plan reports those
  as `:relocated` and leaves them in place, which keeps the UI working; this matches the
  Source contract for pointer-less modules.
- The plan loads every non-trashed person's light row to build the candidate name list.
  One query plus one `name = ANY($1)` lookup; fine at staff scale.

## Validation

`mix precommit` clean; `mix test` 577 tests, 0 failures (integration included).
