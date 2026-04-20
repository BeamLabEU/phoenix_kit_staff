# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-04-20

Initial release.

### Added
- `Departments` context: list/create/update/delete with PubSub broadcasts.
- `Teams` context: list/create/update/delete with department scoping and
  PubSub broadcasts.
- `Staff` context: people CRUD (`Person` schema), team membership
  management, `upcoming_birthdays/1`, `org_tree/0`, and placeholder-user
  flow with transactional rollback.
- Activity logging via safe wrapper pattern, called at the LiveView layer.
- PubSub topic scoping for departments, teams, and people.
- Integration test suite (auto-excluded when `phoenix_kit_staff_test` DB
  is unavailable), including coverage of `upcoming_birthdays/1` (window
  boundaries, today / leap-day / wrap-around DOBs, inactive / nil-DOB
  exclusion, sort order) and `org_tree/0` (team-grouped, dept-only, and
  fully-unassigned buckets).
- `AGENTS.md` with project overview, conventions, testing, and PR policy.

### Performance
- `Staff.upcoming_birthdays/1` filters the day window in Postgres via
  interval arithmetic; only rows inside the window come back.
- `Staff.org_tree/0` loads `TeamMembership` once and derives both the
  team-grouped and unassigned shapes in memory.
