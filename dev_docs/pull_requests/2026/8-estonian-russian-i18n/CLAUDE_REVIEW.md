# Review — PR #8 (phoenix_kit_staff)

**PR:** [Estonian + Russian i18n + Phase 2 sweep](https://github.com/BeamLabEU/phoenix_kit_staff/pull/8)
**Author:** Max Don (max@don.ee)
**Date:** 2026-06-04
**State:** MERGED (+2495/−72, 20 files)
**Reviewer:** Claude (Opus 4.8, 1M context)

## Verdict: ⚠️ Core i18n is correct and complete — but one HIGH packaging bug silently un-translates the published Hex package, plus one adjacent feature gap and two cleanups

The PR gives the staff module its own `PhoenixKitStaff.Gettext` backend (the
hybrid pattern: core owns generics, the module owns its specifics), full et +
ru catalogs, and a Phase 2 quality sweep. The translation work itself is solid
and was verified end-to-end (see "What I verified holds up"). The one finding
that matters is that the new `priv/gettext` is **not** in the Hex package
`files:` list, so a published build ships with an empty catalog and every staff
string reverts to English for downstream consumers.

## What changed (orientation)

| Layer | Change |
|---|---|
| `lib/phoenix_kit_staff/gettext.ex` | NEW — `PhoenixKitStaff.Gettext` backend (`use Gettext.Backend, otp_app: :phoenix_kit_staff`). |
| `priv/gettext/{default.pot, et, ru}` | NEW — 146 domain msgids, fully translated et + ru (incl. plurals). |
| `lib/phoenix_kit_staff.ex` | `use Gettext, backend: PhoenixKitStaff.Gettext`; every `%Tab{}` gets `gettext_backend: PhoenixKitStaff.Gettext`; new `__tab_label_strings__/0` `gettext_noop` anchor so tab labels stay extractable. |
| `lib/phoenix_kit_staff/errors.ex` | Backend switched `PhoenixKitWeb.Gettext` → `PhoenixKitStaff.Gettext` (error strings are domain-specific). |
| `lib/phoenix_kit_staff/web/*_live.ex` (10 LVs) | Backend switched to `PhoenixKitStaff.Gettext`; ~53 truly-generic strings re-routed to core via `Gettext.gettext(PhoenixKitWeb.Gettext, "…")`. |
| `lib/phoenix_kit_staff/web/department_show_live.ex` | Dropped dead `preload: [:teams]` in `mount/3` + the refresh `handle_info/2` (page renders ordered `Teams.list/1`, never read `dept.teams`). |
| `test/phoenix_kit_staff/edge_cases_test.exs` | `status_label/1` pinned to exact "Active"/"Inactive" output instead of `is_binary/1`. |
| `.dialyzer_ignore.exs` | NEW — suppresses the `Gettext.Plural`/`Expo.PluralForms` opaque false positive. |
| `mix.exs` | Added `{:gettext, "~> 0.26 or ~> 1.0"}`. |
| `AGENTS.md` | Gettext convention rewritten to document the hybrid-backend rule. |

## What I verified holds up

These are the parts most likely to be subtly wrong in a cross-backend i18n
change. I checked each against the actual catalogs on disk; all pass.

- ✅ **Every string re-routed to core resolves in core.** All ~53
  `Gettext.gettext(PhoenixKitWeb.Gettext, …)` msgids ("Staff", "Name",
  "Status", "Edit", "Save", "Cancel", "Title", "Type", "Email", "User",
  "Organization", "Add", "All", "Active", "Inactive", "None", "Saving…",
  "Deleting…", "Search", "Clear", "—") are present **and translated** in
  `deps/phoenix_kit/priv/gettext/{et,ru}/LC_MESSAGES/default.po`. No silent
  English fallback at the boundary.
- ✅ **et + ru catalogs are complete.** 146 msgids each, 0 empty `msgstr`,
  0 fuzzy, both plural forms filled (`"1 team"`/`"%{count} teams"` and
  `"🎂 in 1 day"`/`"🎂 in %{count} days"`).
- ✅ **`__tab_label_strings__/0` noop list is correct and complete.** It covers
  exactly the 8 labels with no other call site (`Staff`, `Overview`, and the
  six `New/Edit Department/Team/Staff`). The labels deliberately omitted from
  it (`Department`, `Team`, `Departments`, `Teams`) each have real `gettext/1`
  call sites elsewhere in the LVs, so they're still extracted and translated.
- ✅ **The "🎂 in 1 day" plural is live, not stale.** It's a real `ngettext`
  call site at `person_show_live.ex:88` (the overview's day-0/day-1 path uses
  the separate `"🎂 today!"` / `"tomorrow"` strings).
- ✅ **The dropped `preload: [:teams]` was genuinely dead.** `DepartmentShowLive`
  renders the ordered `Teams.list/1` result; `dept.teams` was never read.

## Findings

### BUG - HIGH (open) — `priv` missing from the Hex package `files:` list

`mix.exs:86`:

```elixir
files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
```

The PR adds `priv/gettext/{et,ru}/…` but never adds `priv` to the package
`files:`. A Gettext backend compiles its `.po` catalogs **from `priv/gettext`
at compile time**. A Hex consumer compiles the published tarball — and if
`priv/` isn't in the tarball, `PhoenixKitStaff.Gettext` compiles with an empty
catalog, so **every staff string falls back to its English msgid** in all
locales. This silently defeats the entire purpose of the PR for any consumer
installing from Hex. `mix hex.publish` does not warn about a missing `priv`,
and the project's publish convention is `mix hex.publish --yes` (no build
preview), so it would ship unnoticed.

Every sibling module that ships gettext includes `priv` in `files:` —
`phoenix_kit_projects`, `phoenix_kit_billing`, `phoenix_kit_emails`, and
`phoenix_kit_crm` all do. `phoenix_kit_staff` is the only one that doesn't.

**Fix:**

```elixir
files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
```

> Note: the module is consumed via a path dep inside this monorepo today, where
> `priv/` exists on disk — so the bug is latent and only triggers on
> `mix hex.publish`. But the module is fully set up for publishing (`package/0`,
> `@version`, a release checklist in AGENTS.md, the global hex-publish
> instruction), so it will trigger the next time it's released.

### IMPROVEMENT - MEDIUM (open, pre-existing) — the multilang JSONB read path is unwired

Not introduced by #8, but directly adjacent to it and worth recording while the
i18n surface is fresh.

The three schemas define localized read helpers — `Department.localized_name/2`
+ `localized_description/2`, `Team.localized_name/2` + `localized_description/2`,
`Person.localized_job_title/2` + `localized_bio/2` + `localized_skills/2` +
`localized_notes/2` — but they have **zero callers** anywhere under `web/`. The
show / list / overview pages render the raw primary-column values
(`@person.job_title`, `@person.bio`, `@person.skills`, `@person.notes`,
`node.department.name`, `t.team.name`, `tm.team.department.name`, …) and no
LiveView reads `@current_locale`.

Net effect: the per-language overrides the multilang forms (`<.translatable_field>`)
collect into the `translations` JSONB are **write-only — never displayed in any
locale**. This PR completes the *UI-chrome* i18n (nav, labels, buttons); the
*data* i18n is still inert.

**Suggested follow-up (separate PR):** thread the active locale into the show /
list / overview LVs (the on_mount hook already injects `@current_locale`) and
swap the raw field reads for the `localized_*/2` helpers, with the existing
primary-fallback semantics. Tracked as a non-blocking follow-up.

### IMPROVEMENT - MEDIUM (open) — 53 runtime `Gettext.gettext(PhoenixKitWeb.Gettext, …)` call sites

53 occurrences across all 10 LVs. Two concerns:

1. **No compile-/extract-time safety.** Unlike the `gettext/1` macro, the
   explicit-backend `Gettext.gettext/2` form is a plain runtime call. A typo, or
   a string later dropped from core's catalog, is **not** caught by `mix compile`
   or `mix gettext.extract` — it silently degrades to the English msgid at
   runtime. (All 53 current msgids do resolve in core today — verified — but the
   contract is unenforced going forward.)
2. **Noise.** The fully-qualified call is heavy inside HEEx and repeated 53×.

**Option:** a thin private bridge imported via the web macro, e.g.
`defp core_gettext(msgid), do: Gettext.gettext(PhoenixKitWeb.Gettext, msgid)`,
plus a one-line comment at the definition explaining the cross-backend reason.
Cuts the per-call-site noise and gives one place to reason about the bridge.
**Trade-off:** the backend is no longer visible at each call site, which is why
the explicit form was chosen — so this is a readability-vs-explicitness judgment
call, not a clear win. Low priority; flagging for a maintainer decision.

### NITPICK (open) — `.dialyzer_ignore.exs` is wired implicitly

The ignore file works via dialyxir's default-filename convention (no
`ignore_warnings:` key in `mix.exs`), which is fine and is exactly what
`phoenix_kit_catalogue` does. But `phoenix_kit_projects` — the module this PR's
own commit message cites as the mirror — wires it **explicitly**:

```elixir
dialyzer: [plt_add_apps: [:phoenix_kit], ignore_warnings: ".dialyzer_ignore.exs"]
```

Adding the explicit key (a) actually matches `projects`, and (b) survives a
future change to dialyxir's default filename. Cheap and more robust.

## Process notes

- **Phase 2 "kept" decisions are sound.** The `attempted_email` activity
  metadata was deliberately retained: it's admin-only, error-path-only, and
  core itself logs the analogous `%{"email" => target.email}` in
  `multi_session.ex`. No real leak; genuine audit value. Agreed.
- **AGENTS.md updated in-PR** to document the hybrid-backend rule — good, the
  convention is non-obvious and now self-documents.
- **No version bump** in this PR. Given the HIGH packaging fix below should ship
  before the next publish, the fix + a patch bump + CHANGELOG entry should land
  together per the release checklist.

## Summary

| Area | Status |
|---|---|
| New `PhoenixKitStaff.Gettext` backend + hybrid routing | ✅ correct; all routed strings resolve in core |
| et / ru catalogs | ✅ 146 msgids each, 0 empty / 0 fuzzy, plurals filled |
| Tab-label extraction (`__tab_label_strings__/0`) | ✅ complete and correct |
| Phase 2: dead `preload` drop, test pin, plurals | ✅ verified |
| **Hex packaging (`files:`)** | 🔴 `priv` omitted → published package ships empty catalog → ✅ **fixed in-tree** |
| Multilang JSONB read path | ⚠️ pre-existing: `localized_*/2` helpers had zero callers → ✅ **wired in-tree** |
| Cross-backend call ergonomics | ⚠️ 53 runtime calls, no extract-time safety → bridge evaluated, deliberately skipped |
| `.dialyzer_ignore.exs` wiring | ⚪ implicit default → ✅ **explicit `ignore_warnings:` added in-tree** |

**Follow-ups (priority order):**

1. **(HIGH, blocking next release)** Add `priv` to `mix.exs` `files:`; bump patch
   version + CHANGELOG; re-publish.
2. **(MEDIUM)** Wire the `localized_*/2` read helpers into the show / list /
   overview LVs so the multilang JSONB overrides actually render (separate PR).
3. **(MEDIUM, optional)** Decide whether to introduce a `core_gettext/1` bridge
   for the 53 cross-backend call sites.
4. **(NITPICK)** Add explicit `ignore_warnings: ".dialyzer_ignore.exs"` to the
   `dialyzer:` config to match `phoenix_kit_projects`.

---

## Follow-up landed in-tree (post-merge, 2026-06-04)

Items 1, 2, and 4 resolved in the working tree; item 3 evaluated and
deliberately **not** applied (rationale below). Version bumped `0.3.0` → `0.4.0`
(`mix.exs` `@version` + `PhoenixKitStaff.version/0`), CHANGELOG `[0.4.0]` entry
added.

| Item | Resolution | Files |
|---|---|---|
| **#1 Hex packaging (HIGH)** | Added `priv` to the package `files:` list, so `mix hex.publish` now ships `priv/gettext/{et,ru}` and the compiled backend has a populated catalog for Hex consumers. Verified every other gettext-shipping sibling (`projects`, `billing`, `emails`, `crm`) does the same. | `mix.exs` |
| **#2 Localized read path (MEDIUM)** | Added `L10n.current_content_lang/0` (mirrors `phoenix_kit_projects` — `Gettext.get_locale/1`, rescued to `nil`). Wired the `localized_*/2` helpers into all 7 read LVs: overview, departments / department-show, teams / team-show, people, person-show. Each LV resolves `@lang` once at the top of `render/1` (locale is reliably set in the process dictionary by render time) and renders Department/Team `name` + `description` and Person `job_title` / `bio` / `skills` / `notes` through the helpers. `data-confirm` name interpolations and the overview person tooltip were localized too. **Behavior is identical to before when no override exists** (the helpers fall back to the primary column), so the change is additive. `name` (single full-name field) and `work_location` (soft-FK) are correctly left un-localized per the schema's translatable-field set. | `lib/phoenix_kit_staff/l10n.ex`, `web/{overview,departments,department_show,teams,team_show,people,person_show}_live.ex` |
| **#4 Dialyzer wiring (NITPICK)** | `dialyzer:` now carries `ignore_warnings: ".dialyzer_ignore.exs"` explicitly alongside `plt_add_apps`, matching `phoenix_kit_projects` and surviving a future change to dialyxir's default filename. | `mix.exs` |

### #3 cross-backend bridge — evaluated, deliberately skipped

A `core_gettext/1` wrapper for the 53 `Gettext.gettext(PhoenixKitWeb.Gettext, …)`
sites was considered and **not** applied:

- It is purely cosmetic (DRY). It does **not** fix the underlying concern —
  the call stays a runtime lookup with no `gettext.extract`-time safety whether
  or not it's wrapped. The only way to gain compile-time safety would be to move
  these generics into the staff domain and use the `gettext/1` macro, which
  deliberately contradicts the PR's "don't re-translate core generics" design.
- It would churn 53 freshly-reviewed call sites across 10 files for marginal
  gain and nonzero regression risk.
- It removes the explicit backend visible at each call site — the very thing
  the author chose by writing the fully-qualified form — and cuts against the
  Elixir "no gratuitous helper functions" guidance.

Recommend leaving the explicit form. Re-open only if the count grows materially.

### Verification

- `mix compile` — clean; `mix compile --warnings-as-errors` — exit 0 (no
  unused-alias or other warnings from the added aliases).
- `mix format --check-formatted` — clean.
- `mix credo --strict` on the 8 touched files — `found no issues`.
- `mix test --exclude integration` — **83 tests, 0 failures**. The 256 integration
  / LiveView smoke tests require a reachable PostgreSQL (not available in this
  environment) and were auto-excluded; the user should re-run the full `mix test`
  from `/www/app` per the documented precommit chain to exercise the LV render
  paths end-to-end. `mix dialyzer` likewise needs the app build and was not run here.
- Cross-checked that the et/ru catalogs already carry the now-rendered field
  values' fallback behavior: no catalog change was needed — the read path keys
  off the stored `translations` JSONB, not gettext.
