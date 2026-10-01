# Codex Review — published Staff 0.10.0

Reviewed on 2026-10-01. Scope: the complete `v0.9.0..v0.10.0` release diff,
including PR #22 and the dependency-floor correction, with surrounding Staff
code and the resolved core component implementations.

## Outcome

No new actionable functional regression or release blocker found in the reviewed
changes. No application code changed during this review.

The missing core slots identified in `CLAUDE_REVIEW.md` are resolved in this
release: the published package requires `phoenix_kit >= 2.43.0 and < 3.0.0`,
the lockfile resolves 2.43.0, and both slot conformance tests pass.

## Published artifact

- Hex identifies 0.10.0 as the latest release, published at
  `2026-10-01T12:57:57.241309Z`:
  <https://hex.pm/api/packages/phoenix_kit_staff/releases/0.10.0>.
- Downloaded `https://repo.hex.pm/tarballs/phoenix_kit_staff-0.10.0.tar`;
  its SHA-256 matches Hex's checksum:
  `d8249e38909cdba7a476c292b17fbb9bfbf4557dcc56c9f16f42692e761a7e47`.
- All 49 files in `contents.tar.gz` match the corresponding files at
  `v0.10.0` byte for byte. The tag points to release commit `80cfe20`.
- Published dependency requirements match the release's `mix.exs`; the
  Locations module remains a runtime-only soft dependency.

## Validation

- `mix test`: **610 tests, 0 failures**, with PostgreSQL integration and LiveView
  tests running. No local PhoenixKit dependency overrides were used.
- `mix precommit`: **passed** — forced compilation with warnings as errors,
  unused-lock check, Hex audit, formatting check, strict Credo, and Dialyzer.
  Hex reports no retired packages or security advisories. Dialyzer uses the
  repository's existing ignore file; its two findings are existing ignores.
- Reviewed the list toolbar and bulk-selection markup against core's component
  and hook contracts, form submit/cancel behavior including the employment
  component target, root/Overview tab routing, department preselection,
  work-location refresh paths, and the schema gettext-backend changes.

## Remaining observations and limits

- The three **NITPICK** items already documented in `CLAUDE_REVIEW.md` and
  `FOLLOW_UP.md` remain: HEEx indentation, the raw Teams table on person show,
  and the People tab regex accepting unrelated paths ending in `/staff`.
  No additional defect was established from them during this review.
- The work-location tests cover nil, free text, absent/unknown locations, and
  deduplicated results. This standalone suite does not install the optional
  Locations module, so successful cross-module name resolution was checked by
  reading its `get_location/1` contract, rather than by an integration test.
- The existing `AGENTS.md` TODO about the location picker's unscoped
  `list_locations(status: "active")` remains unresolved. A staff admin can
  see every owner's locations, including private ones. That behavior predates
  this release; this review does not establish the intended access policy.
- LiveView tests validate server-rendered HTML and events; no browser-level
  visual or JavaScript interaction check was performed.
