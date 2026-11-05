# PR #1 — Initial commit: review record

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5), with a read-only reviewer pass for candidates
**Merge:** `3870fa3`
**Verdict:** the data model and scoping hold up. Several form and delete paths did not. Confirmed defects fixed; the rest recorded below with reasons.

The PR is old, so this reviews what it introduced as it stands on `main`, including later code in its files. Evidence: **run** means a test fails without the fix; **read** means confirmed in the source but not run.

## Findings

### BUG - HIGH: permanent delete from the people list left the media behind (run)

Only `PersonShowLive` called `Attachments.purge_person_media/1`. Deleting from the Trash filter, single or bulk, removed the row and left the `staff-person-<uuid>` folder and its files, with nothing to clean them up. `AGENTS.md` says a permanent delete purges.

Fixed in the context, so no caller can skip it: `Staff.delete_person/1` and `bulk_delete/1` purge. Bulk uses the uuids `delete_all` actually returns, not the input, because a selection can include live people. A test pins that a live person keeps their folder.

### BUG - MEDIUM: a crafted event could re-link a profile to another user (run)

`PersonFormLive` stripped only `metadata` and personal fields, while `Person.changeset/2` casts `user_uuid` and the employment mirror columns. A `save` event with `person[user_uuid]` re-linked the profile, although the page calls it locked. `AGENTS.md`'s "the person form never casts them" held only because no input was rendered. The form now drops all of them.

### BUG - MEDIUM: a rename could overwrite a claimed account's email (run)

`rename_placeholder_email/2` checked `placeholder?` on a struct from mount. If the user claimed the account while the form was open, the check passed and their login email was changed. It now re-reads the user.

### BUG - MEDIUM: a failed save after a rename locked the form (run)

The rename commits before the person update. If the update failed, the retry compared against the stale email, found the renamed user, and answered `:email_already_taken` until a reload. The re-read above resolves this too.

### BUG - MEDIUM: a refused registration blanked the person form (run)

`Staff.create_person_with_user/2` can return core's `User` changeset, which became the form's source: every input rendered blank as `user[...]`, with no message. The form now stays and says "Not a valid email." The rate-limit refusal shows the same text, which is imprecise but no longer a wiped form.

### BUG - MEDIUM: a false "already has a staff profile" on placeholder edit (run)

Any change on the edit form looked up the unchanged email, found the person's own user, and reported a conflict. Unchanged email now reads as no status.

### BUG - MEDIUM: an unknown department raised instead of returning a changeset (run)

`Person.changeset/2` had no constraint on `primary_department_uuid`, so `Ecto.ConstraintError` escaped, and in `create_person_with_user/2` it skipped the placeholder rollback. Added `foreign_key_constraint/3`.

### NITPICK: birthday countdown clamped to the 28th (read, helper tested)

`days_until_birthday/2` in `PersonShowLive` kept the `min(dob.day, 28)` that PR #2 removed from `Org` only: on Dec 31 a Jan 31 birthday showed 28 days, not 31. It now uses `Org.next_birthday_and_days/2`.

### IMPROVEMENT - MEDIUM (not fixed)

- **The Events tab shows no team or skill changes (read).** It filters `resource_type: "staff_person"`, but those rows are logged as `"team"` and `"skill"`, so their labels in `ActivityLabels` are unreachable. Needs a decision on what the feed should hold; existing rows would stay as logged either way.
- **Broadcast gaps leave pages stale (read).** A team moved between departments reaches only the new one; a department delete cascades with no team or person events; team rosters do not hear person events, so a trashed person stays listed until reload; bulk events do not reach `PersonShowLive`. No data effect.
- **Failure-side logging is missing on several `{:error, _}` branches (read),** against the rule in `AGENTS.md`: `PeopleLive`, `PersonShowLive` and the skill sync in `PersonFormLive`. A mechanical sweep that should land on its own.
- **Stale structs raise (read).** `lib/` has no `stale_error_field`, so saving a row deleted meanwhile raises `Ecto.StaleEntryError`. The LiveView crashes and remounts onto "not found", with no audit row.
- **`eligible_users/1` loads every unlinked user (read),** in mount, into a `<datalist>`. Scales with the host's user table.
- **`target_uuid` is inconsistent (read).** Core treats it as a user; team logs pass a person uuid, and one skill action passes either. Existing rows are affected, so this needs a decision.

### NITPICK (not fixed)

Malformed URL uuids give a 400 page, not the not-found flash; `maybe_add_to_team/3` reads `cs.errors` on `{:error, :person_trashed}`, reachable only in a millisecond race; `%` and `_` are not escaped in search; a case-only rename reports `:email_already_taken`; reads in `mount/3` are the module's established pattern outside `PeopleLive`.

## A lead that did not hold

A probe showed a placeholder with `confirmed_at` set, which would have meant renames never work. It was the first user of the sandbox, which core confirms as Owner: a second user stays unconfirmed. Not a defect, and now a landmine in `AGENTS.md`.

## Checked, no finding

Trashed people stay out of `list_people`, `count_people`, `org_tree`, `upcoming_birthdays`, `people_not_on_team`, rosters and `eligible_users`. Duplicate memberships and the 1:1 user link are constraint-backed. No `String.to_atom`. No N+1. `view_personal` holds on show, form and overview.
