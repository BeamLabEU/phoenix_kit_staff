# Follow-up — PR #1 review items 1 & 2

**Date:** 2026-04-20
**Commit:** `000914f` — "Update upcoming_birthdays and org_tree to cut query work"

Addresses the two `IMPROVEMENT - MEDIUM` findings in `AGGREGATED_REVIEW.md` /
`PINCER_REVIEW.md`.

## Item 1 — `upcoming_birthdays/0` loaded all active people into memory

**Fix.** The day-window filter now runs in Postgres. For each person we compute
the next anniversary via interval arithmetic:

```
(dob + (year_diff) * INTERVAL '1 year')::date
```

…then add a year when this year's anniversary has already passed, and filter by
`(next_birthday - CURRENT_DATE) <= window_days`. Only rows inside the window
come back; the Elixir side maps the small result set for display.

**Leap-day DOBs.** Postgres interval math normalizes Feb 29 → Feb 28 in
non-leap years (e.g. `'2000-02-29'::date + INTERVAL '1 year' = 2001-02-28`), so
no manual clamping is needed.

**Validated independently** against live Postgres — returns correct
`days_until` for: today's birthday (0), window boundary days (29/30/31),
leap-day DOBs from 1980 and 2000 (both → 2027-02-28 = 314 days since 2026's
Feb 28 is already past), and past-this-year birthdays (wrap to next year).

## Item 2 — `org_tree/0` ran redundant TeamMembership queries

**Fix.** The function previously ran one query to preload `staff_person + user`
and a *second* query just to collect `staff_person_uuid`s for the
"unassigned" check. Now it loads memberships once and derives both shapes in
memory:

```elixir
all_memberships = repo().all(...)   # preloads staff_person + user
people_by_team   = Enum.group_by(all_memberships, & &1.team_uuid, & &1.staff_person)
person_team_ids  = all_memberships |> Enum.map(& &1.staff_person_uuid) |> MapSet.new()
```

One query saved, identical output. A single-query CTE was considered but
rejected — marginal gain over the 3 preload-shaped queries we already have,
and it would sacrifice the clean `Enum.group_by` transformation.

## Tests

Added `test/phoenix_kit_staff/integration/staff_queries_test.exs` — 17
integration tests covering:

- `upcoming_birthdays/1`: today / boundary / out-of-window / wrap-around /
  Feb 29 DOB / inactive excluded / nil DOB excluded / sort order / default
  window / `window_days = 0`
- `org_tree/0`: empty DB / team-grouped / dept-only / fully-unassigned /
  team-membership overrides dept-only / user preload / team name ordering

Auto-excluded without `phoenix_kit_staff_test` DB (same policy as the other
integration tests).

## Not addressed (yet)

- **Item 3 — email regex.** Intentionally basic per codebase style; real
  validation happens at user confirmation / registration in
  `PhoenixKit.Users.Auth`.
- **Item 4 — `Person` changeset field grouping.** Cosmetic; deferred.
- **Item 5 — `staff.ex` file size.** Still ~440 lines after this change.
  Splitting into `Staff.People` / `Staff.Memberships` / `Staff.Org` makes
  sense when the file grows further; not urgent now.

## Missing follow-up — DB index

`date_of_birth` has no index. With `status='active' + NOT NULL` narrowing
first via `phoenix_kit_staff_people_status_index`, this is fine at current
scale. A partial index `WHERE status = 'active' AND date_of_birth IS NOT NULL`
would let Postgres combine index scan with the fragment; worth adding in a
future `VNN` migration if the org grows large.
