# PR #7 — Multilang, Person.name, work-location soft dep: review record

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5), with a read-only reviewer pass for candidates
**Merge:** `db163ce`
**Verdict:** the translation form path silently lost data. Fixed, with tests that write through a form and read the value back, which nothing did before.

Reviewed as the code stands on `main`. Evidence: **run** means a test fails without the fix; **read** means source reading only.

## Findings

### BUG - HIGH: a translation is lost when the save comes from the primary tab (run)

The primary tab renders no `translations[...]` inputs, so `merge_translations_attrs/3` took the `_ -> Map.delete(attrs, "translations")` branch and dropped what was typed on the other tabs, with a success flash. A primary-tab `validate` dropped it the same way. Reaching Save from the primary tab is the ordinary path: type a translation, click back, save.

Fixed: that branch keeps the in-flight map. Ecto's `cast` skips an unchanged value, so saves that touched no translation still write nothing to the column.

### BUG - MEDIUM: translations stored under a dialect never reach the read pages (run)

Forms store under the tab code (`es-ES`). `L10n.current_content_lang/0` returned the Gettext locale, which core downgrades to a base code (`es`), and the reader did an exact lookup. So a translation looked saved in the form and never appeared on the pages.

**Severity is below what the reader pass proposed.** It rated this HIGH using `et-EE`, which is not a code core offers: `add_language("et-EE")` returns an error. Of core's 140 languages 123 are bare, including `et` and `ru`, the two this module ships catalogues for, and those match exactly. It affects the 17 dialect-coded ones, such as `es-ES`, `fr-FR` and `en-GB`.

Fixed: `current_content_lang/0` reads `Multilang.current_locale/0` (in core since 2.32.0, below the floor), and `L10n.language_entry/2` resolves exact, then base, then same-base dialect. `Skill` uses it too, since its seeds use bare codes.

**Trap avoided:** core's fallback cannot be copied as it stands. Its primary text is an entry; staff's is a column. A primary `en-US` viewer would get an `en-GB` override in place of the primary column. The sibling step skips primary viewers, with a test.

`test/support/hooks.ex` claimed to mirror production but put the raw dialect on Gettext, which is why this stayed hidden. It now calls core's `put_gettext_locale/1`.

### BUG - MEDIUM: an override could not be removed (run)

Clearing a language-tab field dropped the `""`, and the merge kept the old key, with a success flash. The code comment promised the opposite. A blank value now removes the override, and a language left empty goes too.

### BUG - MEDIUM: the person form wrote server-owned data from a stale copy (run)

`merge_attrs` passed `Person.translatable_fields()` (`job_title bio notes`) although the form edits only `bio`. A save re-injected the mount-time `job_title` onto the re-fetched row, undoing `Employments.sync_current/1`, and a language-tab save wrote the whole stale `translations` map over it.

Fixed: only `bio` is preserved, and `translations` are rebased on the re-fetched row (`Web.Helpers.rebase_translations/3`). This also ends a viewer without `staff.view_personal` restoring `notes` overrides from the mount-time struct.

### BUG - MEDIUM: clearing a primary field was undone by a save from a language tab (run)

`preserve_primary_fields` skipped a nil in-flight value, so a cleared `description` kept its stored value. It now carries nil.

**Part of this report did not hold:** a cleared *required* `name` keeps its stored value by design. `validate_required` drops the invalid change, so in-flight still holds the name. No data is lost; not a bug.

### BUG - MEDIUM: editing a span wiped a location missing from the active list (read, helper unit-tested)

The picker lists active locations only. A deactivated location or legacy free text selected nothing, submitted `""`, and cast to nil, also clearing `Person.work_location` on the current span. `Web.Helpers.location_choices/2` adds the stored value. The template wiring is not exercised: no `PhoenixKitLocations` module exists in this test suite.

### BUG - MEDIUM: "Add employment" lost what it says it carried over (run)

The new span used submitted params alone, so a hidden picker's location and the title's translations were lost, and `sync_current` then cleared both from the person. `carry_over/2` keeps the location, and keeps translations only while the title is unchanged, since a new title's overrides would be wrong.

### IMPROVEMENT - MEDIUM (not fixed)

- **Primary names shown where `AGENTS.md` wants `localized_*`:** the employment timeline and the department and team pickers. Display only.
- **Search misses the displayed name:** `maybe_filter_search` matches `p.name` and email, but `display_name/1` falls back to the user's first and last name. The doc says "name or user email", so this is a gap, not a broken promise.
- **Location names are never localized.** Needs a public reader on the locations side first.

### Suspicion, not confirmed

Changing the primary language could leave an override that shadows the column, since the exact tier wins and the primary tab cannot remove it. Not observed.

### NITPICK (not fixed)

Whitespace passes `display_name/1` and the override check; `person_show_live.ex` gates `bio` on the primary column, hiding a translated-only bio; `work_location_label/1` has no `catch :exit`.

## Outside this repo

`phoenix_kit_projects` has verbatim copies of the merge helper (`web/helpers.ex`) and the Gettext read (`L10n.current_content_lang/0`), so it has the same bugs. Not touched.

## Correction to an earlier record

`12-post-0.5.0-staff-features/CLAUDE_REVIEW.md` says `current_locale` and the content locale "resolve to the same string in normal operation". They do not on a dialect-coded host. Left as written, since a review file belongs to its run.

## Checked, no finding

Reader shape safety; every listed field has a reader; `Person.name` and `work_location` correctly untranslated; the `multilang_fields_wrapper` landmine in all forms; the soft dep with the module absent, disabled or raising; `notes` behind `staff.view_personal`.
