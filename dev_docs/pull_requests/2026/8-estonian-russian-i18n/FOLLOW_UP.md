# Follow-up — PR #8 (Estonian + Russian i18n + Phase 2 sweep)

After-action triage of `CLAUDE_REVIEW.md`. The review's own
"Follow-up landed in-tree (post-merge, 2026-06-04)" section resolved findings
#1, #2, #4 and deliberately skipped #3; this doc formalizes that record in the
canonical format and **re-verifies every disposition against current code**
(2026-06-17). One previously-fixed item has since **regressed** — see below.

## Fixed (in-tree, post-merge 2026-06-04 — re-verified 2026-06-17)

| Finding | Severity | Disposition |
|---|---|---|
| `priv` missing from Hex package `files:` → published build ships an empty catalog | BUG-HIGH | **Fixed & still live** — `mix.exs:111` is `files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)`. Matches every gettext-shipping sibling. |
| `.dialyzer_ignore.exs` wired only implicitly | NITPICK | **Fixed & still live** — `mix.exs:27-29` carries `dialyzer: [plt_add_apps: […], ignore_warnings: ".dialyzer_ignore.exs"]` explicitly, matching `phoenix_kit_projects`. |

## Regressed since the review (caught in this sweep, 2026-06-17)

| Finding | Severity | Disposition |
|---|---|---|
| Multilang JSONB read path unwired (`localized_*/2` helpers had zero callers) | IMPROVEMENT-MEDIUM | **Re-opened.** PR #8 fixed this by adding `L10n.current_content_lang/0` and wiring `localized_*/2` into the 7 read LVs. PR #10's v0.5.0 reshape (`964d320`) rewrote those render bodies and **dropped all of it**: `current_content_lang/0` is gone from `l10n.ex` (0 refs), and `localized_*` now appears once in `web/` (only the new `person_employment_component.ex`). Per-language overrides the multilang forms collect are **write-only again**. **Being restored in this sweep (Phase 2)** with pinning tests so a future render-body rewrite can't silently drop it again. |

## Skipped (with rationale)

- **#3 — `core_gettext/1` bridge for the explicit `Gettext.gettext(PhoenixKitWeb.Gettext, …)` sites.** Evaluated and deliberately not applied at review time: it's purely cosmetic (DRY) and doesn't add `gettext.extract`-time safety; it removes the backend visible at each call site; it churns freshly-reviewed sites for marginal gain. The review set the trigger "re-open only if the count grows materially." **Status update:** the count has grown **53 → 102** (the post-April surfaces — employment / events / media / skills selectors — added ~49 more), so the trigger is arguably met. Surfaced as an open decision below rather than acted on unilaterally.

## Files touched

| File | Change |
|---|---|
| (none in this Phase 1 triage) | Findings #1/#4 were fixed in-tree at review time; #2's restoration + #3's decision are handled in the Phase 2 sweep, tracked there. |

## Verification

- `mix.exs` re-read on current code: `priv` present in `files:`; explicit
  `ignore_warnings:` present. Both review fixes still live.
- Regression confirmed by grep: `current_content_lang` = 0 occurrences in
  `l10n.ex`; `localized_*` = 1 occurrence in `web/` (the employment component).
- Full-suite / precommit verification for the localized restoration lands with
  the Phase 2 sweep commit, not this triage.

## Open

1. **Multilang read-path restoration** — in progress in this sweep (Phase 2);
   this entry flips to *Fixed in `<commit>`* once it lands.
2. **`core_gettext/1` bridge decision (#3)** — the cross-backend call count
   doubled (53 → 102), meeting the review's "re-open if material" trigger.
   Needs a maintainer call: introduce the bridge, or keep the explicit form and
   raise the re-open threshold. Not blocking.
