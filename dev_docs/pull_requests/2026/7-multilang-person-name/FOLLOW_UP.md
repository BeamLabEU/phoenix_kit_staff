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
- The NITPICKs in the review.

## Closed since

- **A last override blanked, then saved from the primary tab, stayed (run).** `merge_translations_map/2` dropped an empty in-flight map, so the save carried nothing. It now always carries the map. Found while porting these fixes to `phoenix_kit_projects`. `PersonFormLive` writes onto the re-fetched row, so it also skips the write when the form changed no translation; without that, an untouched form would have wiped a `bio` saved since it opened. Fixed in 0.11.2.
- `phoenix_kit_projects` had the same merge helper and Gettext read (0.33.0 included). The fixes are ported there; it also needed `Web.Helpers.maybe_put_locale/1` to take a dialect, since its pages hand `current_content_lang/0` to nested LiveViews.
