# Follow-up Items for PR #22

Triaged against `main` on 2026-10-01, from `CLAUDE_REVIEW.md`.

## Fixed

- **BUG - CRITICAL** PR needs unreleased core slots — made visible, not
  resolved. Added `test/core_slots_conformance_test.exs` (asserts
  `table_default :toolbar_primary` and `form_section :actions` exist on the
  resolved `:phoenix_kit`; one clear failure message instead of 87 LiveView
  errors). Fails on core 2.42.1, passes against `PHOENIX_KIT_PATH=../phoenix_kit`.

## Open

- ~~**Release blocker**~~ — resolved 2026-10-01: core 2.43.0 is published and
  carries both slots. The `:phoenix_kit` floor is now `>= 2.43.0 and < 3.0.0`
  (`mix.exs`, `core_pin_conformance_test.exs`, `AGENTS.md`), the lockfile is on
  2.43.0, and `mix test` against Hex passes (610 tests, 0 failures) with
  `mix precommit` clean. Released as 0.10.0.
- **NITPICK** HEEx indentation drift in the migrated templates — needs
  `Phoenix.LiveView.HTMLFormatter` configured in `.formatter.exs`; separate change.
- **NITPICK** Person show's Teams table still a raw `<table>`.
- **NITPICK** People tab regex is left-unanchored.

## Verification

- `mix test` on the lockfile's core 2.42.1: 87 failures, all from the two
  missing slots (grouped by file; all `ArgumentError … __slot__: :actions` or
  slot warnings).
- `PHOENIX_KIT_PATH=../phoenix_kit mix test`: 608 tests, 0 failures (610 with
  the new conformance tests, which pass there).
- `PHOENIX_KIT_PATH=../phoenix_kit mix precommit`: passes (compile
  `--warnings-as-errors`, format, credo `--strict`, dialyzer).
