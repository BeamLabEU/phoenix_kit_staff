# Claude Review — PR #19 "Attachment folders under a host-configured parent"

**Merge commit:** 5359378
**Author:** Timujeen (timujinne/feat/attachments-parent-folder)
**Files:** `lib/phoenix_kit_staff/attachments.ex`, `test/phoenix_kit_staff/attachments_parent_folder_test.exs`, `CHANGELOG.md`

## Summary of the change

Adds an optional host hook `config :phoenix_kit_staff, :attachments_parent_folder, {mod, fun}`
so a person's `staff-person-<uuid>` root folder is created under a parent folder instead of
at the storage root. `get_folder/2` gained a fallback (under the parent, then at root) so
folders that predate the setting are still found. `ensure_folder(:images)` now builds on
`ensure_folder(:files)`.

The goal is sound and the legacy-root fallback is the right call. The hook's answer,
though, feeds the read paths as well as the create path, and the read paths call it with
different arguments.

## Findings

### 1. BUG - MEDIUM — Read and purge paths resolve the folder with a different hook answer than the create path

The hook is called with `actor_uuid`, which advertises that its answer may vary by actor.
Only `ensure_folder/3` passes one, though:

- `PersonMediaComponent.update/2` calls `Attachments.folder_uuid(person.uuid, kind)`, so the actor is `nil`.
- `purge_person_media/1` calls `parent_folder_uuid(:person, nil)`.

With a hook like "each admin's uploads go under their own folder" (or any hook that
returns `nil` for a `nil` actor):

- **Media disappears after a reload.** The upload creates `staff-person-X` under parent A.
  The next mount resolves with actor `nil`, gets root, misses the folder, and the Files and
  Images tabs render empty. The files are still in storage.
- **Twin folders.** A second admin's `ensure_folder` resolves parent B, misses A, and
  creates a second `staff-person-X` under B. The unique index is `[:name, :parent_uuid]`,
  so nothing stops it. The person's media is now split across two folders.
- **Orphaned media on permanent delete.** Purge looks under the hook's `nil`-actor parent,
  then root, misses the folder, and returns `:ok`. The person's files are never deleted.

**Fix applied.** The hook now only decides where a *new* folder is created. The root
folder name embeds the person uuid, so every folder carrying it belongs to that person.
`find_root_folder/2` loads the folders with that name (normally one) and picks them in
this order: under the configured parent, then at root, then under any other parent,
oldest uuid first within a rank. The answer no longer depends on who is asking.
`purge_person_media/1` deletes every folder with the name and doesn't consult the hook.
The component also passes the actor to `folder_uuid/3` now, for consistency.

### 2. IMPROVEMENT - MEDIUM — `subject` is always `nil`

The moduledoc calls `parent_for(:person, actor_uuid, subject)` the preferred contract,
but no caller ever passed a subject. A host couldn't route per person (for example by
department). **Fix applied:** the person uuid is passed as the subject on every call.

### 3. NITPICK — Hook `:exit` not caught

`parent_folder_uuid/3` rescues exceptions but not exits. A hook that calls a GenServer
that times out would crash the media tab's `update/2`. The repo's other runtime guards
(`PhoenixKitStaff.Activity`) catch `:exit` too. **Fix applied:** `catch :exit`, falling
back to root.

### 4. NITPICK — Moduledoc mentions an "avatar check" that doesn't exist

The avatar is a file pointer in `Person.metadata` and never resolves a folder.
**Fix applied:** the moduledoc now describes the actual lookup and purge semantics.

### 5. NITPICK — DB-backed test in the unit directory

`test/phoenix_kit_staff/attachments_parent_folder_test.exs` uses `DataCase`, so it is
tagged `:integration` and skips correctly. The repo keeps DB-backed tests under
`test/phoenix_kit_staff/integration/`, though. **Fix applied:** the test moved there and was
extended to cover:

- actor-dependent hooks (render with no actor, a second actor, no twin)
- the subject being the person uuid
- the 2-arity hook
- a hook that raises or exits
- purge removing same-named folders under different parents

### 6. NITPICK — Hook runs on every media-tab `update/2` (not fixed)

`folder_uuid/3` calls the hook on every component update. A host hook that queries or
find-or-creates its parent folder turns every re-render into a query or a write, and a
find-or-create hook breaks the "viewing a tab doesn't spawn folders" rule. This is left
as host responsibility: the hook should be a cheap lookup. The resolver itself still
issues a single query.

### Pre-existing, out of scope (not fixed)

Folder lookups don't filter `Folder.trashed_at`. If an admin trashes a person's folder in
`/admin/media`, staff keeps resolving and uploading into it. This predates the PR.

## Verdict

Merged as is, but finding 1 made the feature unsafe for any hook whose answer depends
on the actor. Fixed post-merge, with regression tests.
