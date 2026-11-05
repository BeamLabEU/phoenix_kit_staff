# PR #24 — Never lower the staff chain's marker: review record

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5)
**Merge:** `bf3fd94`
**Verdict:** the guard is the right idea, but one path still lowers the marker. Fixed here, with the untested `flush()` covered.

Evidence: **run** means a test fails without the fix; **read** means source reading only.

## Findings

### BUG - MEDIUM: a target past this code's chain still lowers the marker (run)

`up/1` compared the marker with the raw `target`, while `up_statements/2` stamps `min(target, @current_version)`. A database ahead of the code with a target at or above its marker passed the guard, then the clamped stamp lowered it. Reproduced before the fix: marker `2`, `up(version: 3)`, code at V1, marker became `1`. That is the outcome the PR rules out ("never lowers the marker").

Reachable after a downgrade or a dependency pinned backwards, which core reports as `:ahead_of_code`.

The guard was copied from `phoenix_kit_ecommerce`, where it is safe: ecommerce's `up_statements/2` refuses `target > @current_version`. Staff's clamps, so the copy lost the condition it relied on.

### IMPROVEMENT - MEDIUM: `flush()` had no test (run)

The PR says each test fails without its fix, but nothing ran two chains in one migration, so removing `flush()` left every test green. Added a migration that queues a marker and then calls `up/1`. Confirmed it fails with `flush()` removed.

### NITPICK: the docs state the projects trigger as fact

`AGENTS.md`, the `@doc` and the test moduledoc say projects runs this chain before its own. On `main` it does not: nothing in projects' `lib/` calls it, and the call arrives with BeamLabEU/phoenix_kit_projects#62, still open. The PR body orders the two releases, so this is correct once #62 lands. Left as written.

## Checked, no finding

- `marker_query` joins `pg_class`, so a missing table gives zero rows and reads as 0: a fresh install passes the guard.
- `flush()` and `repo().query!` run on the migration's connection, inside its transaction.
- Target validation still happens on a database past the target (`up_statements/2` runs first).
