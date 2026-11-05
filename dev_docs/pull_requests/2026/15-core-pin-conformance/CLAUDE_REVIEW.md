# PR #15 — Conformance test for the :phoenix_kit requirement: review record

**Author:** Max Don
**Reviewer:** Claude (Opus 5.5)
**Merge:** `06bd630`
**Verdict:** the test does its job, and its `@must_admit` / `@must_reject` lists are current. Its prose was not. Fixed.

## Findings

### IMPROVEMENT - MEDIUM: the failure message prescribes a pin that fails the test (read)

When 0.11.0 widened the pin to `>= 2.65.0 and < 4.0.0`, the version lists moved and the text did not. The failure message told the reader to keep `>= 2.43.0 and < 3.0.0`, which `@must_reject` and `@must_admit` both refuse, and the moduledoc explained the old floor. Updated both, with the actual reason for the floor from the 0.11.0 CHANGELOG.

`AGENTS.md` carried the same stale pin; see #18.

## Checked, no finding

`resolved_requirement/0` and `committed_requirement/0` behave as described under `PHOENIX_KIT_PATH`, and a committed `path:` dep still fails the test.
