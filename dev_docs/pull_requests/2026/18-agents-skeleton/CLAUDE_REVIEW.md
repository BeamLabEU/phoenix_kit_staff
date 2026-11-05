# PR #18 — AGENTS.md onto the shared skeleton: review record

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5)
**Merge:** `7b0478e`
**Verdict:** the restructure is sound. `@version` from `Mix.Project.config()` is correct, and the preflight is a real improvement. The document has since drifted from the code, so each statement was checked against the source. Fixed.

## Findings

### IMPROVEMENT - MEDIUM: `AGENTS.md` no longer matched the code (read)

- **Core pin:** said `>= 2.43.0 and < 3.0.0` in two places; `mix.exs` has `>= 2.65.0 and < 4.0.0`. `phoenix_kit_comments` said `~> 0.3`; it is `~> 0.5`.
- **Consumers:** said projects is an optional dep calling only `enabled?/0`. It is a mix dep (`~> 0.11`) and also calls `Paths.person/1`, `Paths.team/1`, `Paths.department/1` and `Staff.create_person/1`. Those three were missing from the stable API table, so renaming one looked safe.
- **Table ownership:** said core's chain still creates the tables. True of 2.x, not of core 3.x, which the pin admits.
- **Test setup:** said `psql` decides exclusion. This PR replaced that with the preflight.
- **Person deletion:** said sibling FKs are all `SET NULL`; projects' assignee-set rows `CASCADE`.

### NITPICK: `Code.ensure_loaded?` guard around the preflight (read)

This PR kept a fallback for cores without `PostgresPreflight`. The floor is now 2.65.0, so it was dead, and it was removed with the #4 fix. Its comment still said the floor was `~> 2.0`.

## Left as they are

The `requires_module_chain_check` and `requires_core_expected_schema` exclusions in `test_helper.exs` are also dead at this floor. Harmless, and they do not hide anything.
