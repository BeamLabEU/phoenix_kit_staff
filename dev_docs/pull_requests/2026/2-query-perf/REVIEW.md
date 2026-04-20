# Review — PR #2 (phoenix_kit_staff)

**PR:** [Update upcoming_birthdays and org_tree to cut query work](https://github.com/BeamLabEU/phoenix_kit_staff/pull/2)
**Author:** Max Don (mdon)
**Date:** 2026-04-20
**State:** MERGED (commit `000914f`)
**Reviewer:** Claude (Opus 4.7)

## Verdict: ✅ Ship-quality — one subtle display bug worth a follow-up

Addresses PR #1 review items 1 & 2. Pushes the birthday-window filter into
Postgres via interval arithmetic so `upcoming_birthdays/1` no longer loads
every active person into memory, and collapses `org_tree/0`'s two
`TeamMembership` queries into one. Adds 17 integration tests.

## Correctness

### BUG - LOW (display drift) — SQL/Elixir leap-day inconsistency

`staff.ex:284` calls `next_birthday_and_days/2` (defined at `staff.ex:290`)
to compute display fields for rows the SQL filter already admitted.

- The SQL filter uses `INTERVAL '1 year'` arithmetic, which **preserves** Feb
  29 in leap target years (`2000-02-29 + 28y = 2028-02-29`).
- The Elixir helper unconditionally clamps the wrap-to-next-year branch with
  `min(dob.day, 28)`, regardless of whether `today.year + 1` is a leap year.

Result: in a leap target year, `next_birthday` shows Feb 28 and `days_until`
is off by 1 compared to the SQL filter's own computation. The row still
passes the window filter (SQL says it's in), but the displayed date/count
is wrong.

**Fix sketch:**

```elixir
defp next_birthday_and_days(dob, today) do
  this_year =
    case Date.new(today.year, dob.month, dob.day) do
      {:ok, d} -> d
      {:error, _} -> Date.new!(today.year, dob.month, 28)
    end

  next =
    if Date.compare(this_year, today) == :lt do
      next_year = today.year + 1
      day = if Date.leap_year?(next_year), do: dob.day, else: min(dob.day, 28)
      Date.new!(next_year, dob.month, day)
    else
      this_year
    end

  {next, Date.diff(next, today)}
end
```

Otherwise behavior is preserved; the new `max(window_days, 0)` guard is a
nice defensive touch.

## Code quality

- The 7-bind heredoc fragment at `staff.ex:264-279` is correct but brittle —
  `p.date_of_birth` appears six times and the CASE re-computes the same
  expression in both branches. A macro wrapper (e.g. `next_anniversary(dob)`)
  or a `subquery` / CTE would read better, but given this file is already
  ~440 lines and the follow-up doc flags a future split, leaving it is
  reasonable.
- `org_tree/0` at `staff.ex:327-330`:
  `all_memberships |> Enum.map(& &1.staff_person_uuid) |> MapSet.new()`
  can be `MapSet.new(all_memberships, & &1.staff_person_uuid)` to skip the
  intermediate list. Micro-optimization.
- `list_people()` is still fetched wholesale and iterated per department for
  `dept_only_people`. Fine at current scale; worth noting as the org grows.

## Performance

- The SQL fragment is **not sargable** — no index can serve it. The
  `status = 'active'` index handles the narrowing; the FOLLOWUP doc
  correctly flags a future partial index on
  `(status, date_of_birth) WHERE status = 'active' AND date_of_birth IS NOT NULL`.
  Good call to defer.
- One query shed from `org_tree/0` as advertised.

## Tests (`test/phoenix_kit_staff/integration/staff_queries_test.exs`)

- Boundary coverage (today / day-30 / day-31 / `window_days = 0`) and
  exclusion paths (inactive, nil DOB) are tight.
- `async: false` is correct given shared DB state.
- Helpers (`unique_email/0`, `create_person/1`) prevent cross-test collisions.
- **Gap:** the Feb 29 test is deliberately loose (`days_until >= 0 and <= 366`).
  It would have caught the leap-day drift if tightened to assert
  `days_until == Date.diff(next_birthday, today)` AND that
  `next_birthday.day == 29` when `today.year + 1` (or `today.year`) is a leap
  year. Worth adding in the follow-up.

## Security

- Fragment uses parameterized bindings (`^window_days`; `p.date_of_birth` via
  Ecto refs). No injection surface.

## Summary

| Area | Status |
|---|---|
| Perf win claimed | ✅ delivered |
| Correctness | ⚠️ leap-day display drift (low-severity) |
| Tests | ✅ thorough, one gap |
| Style | ✅ acceptable; fragment is verbose but isolated |
| Security | ✅ no concerns |

**Follow-up suggested:**
1. Make `next_birthday_and_days/2` leap-year aware (fix above).
2. Tighten the Feb 29 test to assert `next_birthday` and `days_until`
   consistency against `Date.diff/2`.
3. (Deferred) partial index on `(status, date_of_birth)` when scale warrants.
