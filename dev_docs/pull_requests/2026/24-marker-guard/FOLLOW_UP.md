# Follow-up — PR #24

## Fixed

- **Clamped target lowered the marker.** `up/1` compares against `min(target, @current_version)`. Test: `migrations_up_guard_test.exs`, "a target past this code's chain does not lower a newer database's marker".
- **`flush()` untested.** Test: "work queued earlier in the same migration is seen before the marker is read", confirmed to fail with `flush()` removed.

## Open

- Docs describe projects#62 as landed. Correct once it merges; no action here.
