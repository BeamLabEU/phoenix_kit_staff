# Follow-up — PR #4

## Fixed

- **Schema-build failures excluded the integration suite.** `test_helper.exs` restructured; exclusion now depends only on the preflight and `start_link`. Verified against a missing, a stale and a healthy database.
- **Stale comments** in `test_helper.exs`.

## Open

None. Note that `phoenix_kit_staff_test` on the shared host needs `mix test.reset` before `mix test` runs there.
