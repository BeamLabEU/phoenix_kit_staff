# Follow-up — PR #7

## Fixed

Tests are in `test/phoenix_kit_staff/web/multilang_forms_test.exs` unless noted.

- **Translation lost on a primary-tab save.** `Web.Helpers.merge_translations_map/2` keeps the in-flight map.
- **Dialect translations never read back.** `L10n.current_content_lang/0` reads the request dialect; `L10n.language_entry/2` is the one lookup; `Skill` uses it. Unit tests in `l10n_test.exs`.
- **Overrides could not be removed.** `apply_submitted_translations/2`.
- **Person form wrote server-owned data.** `@server_owned`, `@translatable_fields`, `rebase_translations/3`.
- **Clearing a primary field undone.** `preserve_primary_fields/3` carries nil.
- **Span edit wiped an inactive location.** `Web.Helpers.location_choices/2`, unit tests in `helpers_test.exs`. Template wiring not exercised.
- **"Add employment" lost carried values.** `carry_over/2`.
- **Test hook did not mirror production.** `test/support/hooks.ex` calls core's `put_gettext_locale/1`.

## Open

- Localized names in the timeline and pickers.
- Search by the user's first and last name.
- Localized location names (needs a public reader in `phoenix_kit_locations`).
- Primary-language switch leaving a shadowing override (unconfirmed).
- `phoenix_kit_projects` carries the same merge helper and Gettext read.
- The NITPICKs in the review.
