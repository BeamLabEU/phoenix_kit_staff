# Claude Review — PR #22 "Land Staff on the people list and move the module onto core components"

**Merge commit:** bf29fea
**Author:** Dmitri Don (mdon/main)
**Files:** 47 files — `PhoenixKitStaff` tabs, `Paths`, `L10n`, every schema's gettext backend, every staff LiveView (lists, forms, show pages, person tab components), `Web.Helpers`, gettext catalogs, tests, `AGENTS.md`, FOLLOW_UP docs for PRs #12–#21.

## Summary of the change

- The `Staff` sidebar tab now redirects to its first subtab; the people list is the landing page (`/admin/staff` and `/admin/staff/people` render the same LiveView) and the Overview moves to `/admin/staff/overview`. Tab priorities shift, the People tab matches through a regex.
- Every list's create button moves into its table's `:toolbar_primary`; lists and detail pages move onto core's `table_default`, `form_section`, `form_actions`, `section_header`, `status_badge` and `empty_state` components; empty lists render inside the table with a call to action.
- Schemas move from core's gettext backend to `PhoenixKitStaff.Gettext`, keeping core's backend (via `gettext_with_backend/3`) for strings core already translates.
- Work locations: a person's `work_location` (a stored uuid) is resolved to the location's name on person show and in the employment timeline, once per distinct location.
- `Paths.new_team/1` + `?department=` preselect on the team form.

## Findings

### 1. BUG - CRITICAL — The PR needs a core release that does not exist yet; against published core 2.42.1 the module crashes

Two core slots the PR fills are not in any published `phoenix_kit`:
`table_default`'s `:toolbar_primary` and `form_section`'s `:actions`. They are
in core's `Unreleased` section (commits `3526bcae5`, `404eae489`), after the
`v2.42.1` tag. `mix.exs` still pins `>= 2.38.0 and < 3.0.0`, so a host (or CI)
that resolves from Hex gets 2.42.1 and:

- `mix compile --warnings-as-errors` fails (`undefined slot "toolbar_primary"` ×4,
  `undefined slot "actions"` ×2);
- every page that fills `form_section :actions` (person, team, department,
  skill show pages) raises at render — `ArgumentError: lists in Phoenix.HTML
  and templates may only contain … got invalid entry: %{__slot__: :actions}`;
- `mix test` against the lockfile (core 2.42.1): 608 tests, **87 failures**
  across 11 files. Against `PHOENIX_KIT_PATH=../phoenix_kit`: 608 tests, 0
  failures, `mix precommit` clean.

Why it matters: the merge to `main` is fine for the author (who develops
against the local core checkout), but any release of `phoenix_kit_staff` cut
now would ship pages that crash for every host on a published core. This is
the "two things that must stay in sync" case: the pin floor is the contract,
and the PR changed what the code needs without changing it.

Not fixable here by picking a number: the release that carries the slots is
not published, so there is no floor to write. Done instead:

- Added `test/core_slots_conformance_test.exs`, which asserts the two slots
  exist on the resolved core and, when they do not, fails with one message that
  names the cause and the remedy instead of 87 unrelated LiveView errors. Fails
  on 2.42.1, passes on the local checkout.
- Recorded in `FOLLOW_UP.md` that the staff release is **blocked on the core
  release**, and that the release commit must raise the `:phoenix_kit` floor
  to it (keeping the compound `>= x.y.z and < 3.0.0` form).

### 2. NITPICK — HEEx indentation drifted in the migrated templates

Several `~H` blocks lost their nesting when elements were swapped for core
components (e.g. `<.form_actions>` flush with its siblings in the department and
team forms; `<dl>` under `form_section` in `person_show_live.ex` at column 4; the
`<.table_default_row>` cells in the three list LiveViews at the row's own level).
`mix format` passes because the project does not configure
`Phoenix.LiveView.HTMLFormatter`, so nothing normalises it. Behaviour is
unaffected; not fixed, to keep this review's diff to the one real finding.
Adding the HTML formatter plugin would be its own change.

### 3. NITPICK — Person show's Teams section is still a raw `<table>`

Every other table in the PR moved to `table_default`; the Teams table in
`person_show_live.ex` was wrapped in `form_section` but left as a bare `<table>`.
Cosmetic inconsistency only. Not fixed.

### 4. NITPICK — People tab regex is left-unanchored

`~r{(?:^|/)staff(?:/people(?:/.*)?)?$}` also matches any path that merely ends in
`/staff` (e.g. another module's `/admin/foo/staff`), highlighting People there.
Practically unreachable under the `/admin/…` tree and harmless; not changed.

## Verified OK

- **Gettext:** every string the schemas and `L10n` now look up on
  `PhoenixKitStaff.Gettext` is in `default.pot` with a non-empty `et` and `ru`
  translation; the strings that stay on core's backend (`Active`, `Inactive`,
  `Trashed`, month names) are translated in core's `et`/`ru` catalogs.
- **Redirecting tab:** `redirect_to_first_subtab` plus the parent and People tabs
  both pointing at `PeopleLive :index` is consistent; `Paths.index/0` (the
  section link) now leads to the people list, and `Paths.overview/0` was added
  for the Overview. Every internal `Paths.index()` use is the section link.
- **Empty states / column counts:** the `colspan` of each empty-state row matches
  its header (people 6, others 3); the people empty state distinguishes trash,
  filtered and first-run.
- **Team preselect:** `?department=` is checked against the loaded options, so an
  arbitrary value is ignored; the lookup happens in `mount/3` from params only (no
  extra query).
- **Work location labels:** one lookup per distinct location, rescued, and a
  value that is not a uuid or a location that is gone shows as stored; assigned
  on mount, reload and PubSub refresh in person show.
- **Landmines respected:** `UrlState` assigns are still not re-assigned in
  `mount/3`; the list still loads in `handle_url_state/2`.
