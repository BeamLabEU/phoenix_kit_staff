# PR #17 — PGDATABASE and PGPOOL overrides: review record

**Author:** Tymofii Shapovalov
**Reviewer:** Claude (Opus 5.5)
**Merge:** `9f06a78`
**Verdict:** no bugs. It matches core's `config/test.exs`, and it let this review run on its own database rather than dropping a shared one.

## NITPICK (not changed, to stay aligned with core)

- `PGDATABASE` is also libpq's standard variable, so a value exported for other tools silently retargets the suite, and `mix test.reset` drops whatever it names. A role that may not create a database usually may not drop that one, which limits the reach.
- The override ignores `MIX_TEST_PARTITION`, so partitioned runs share one database.
- A whitespace-only `PGDATABASE` becomes `""`.

Any of these would be better changed in core and copied here, not diverged from in one module.
