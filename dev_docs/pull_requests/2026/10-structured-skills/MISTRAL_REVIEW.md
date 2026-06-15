# Mistral Review — PR #10 Follow-up Audit

PR #10 introduced structured skills, per-skill dynamic proficiency levels,
soft-delete for people, the Comments tab, and a quality sweep. This review
audits the post-merge state after the Kimi and Claude review fixes were
applied to `main` via commits `2245c30`, `1241b90`, `07dafb8`, and `92062a3`.

## Audit scope

This is a **follow-up audit** of PR #10's review trail. It checks:
- Whether findings from prior reviews (Claude, Kimi) were fully addressed
- Whether any items remain open
- Whether the codebase remains consistent with its own soft-delete hardening standards

## Prior review cross-check

### Claude Review (`CLAUDE_REVIEW.md`)

| Finding | Status | Notes |
|---------|--------|-------|
| BUG - HIGH: Packaging regression | **FIXED** | `mix.exs` restored in `964d320` |
| BUG - HIGH: Org-tree roster sort crash on nil email | **FIXED** | Nil-safe sort in `staff/org.ex` in `964d320` |
| IMPROVEMENT - HIGH: `PeopleLive` double query | **FIXED** | Redundant `load_people` removed in `964d320` |
| IMPROVEMENT - MEDIUM: Search debouncing | **FIXED** | `phx-debounce="300"` added in `964d320` |
| BUG - MEDIUM: `PersonFormLive` swallowed skill-sync errors | **FIXED** | `with` → `case` with logging in `964d320` |
| NITPICK: Stale comment | **FIXED** | Updated in `964d320` |

### Kimi Review (`KIMI_REVIEW.md`)

| Finding | Status | Notes |
|---------|--------|-------|
| BUG - MEDIUM: `person_counts/0` included trashed | **FIXED** | Inner join + filter added in `2245c30` |
| IMPROVEMENT - MEDIUM: Context functions guard against trashed | **⚠️ OPEN** | Flagged for follow-up, not implemented |
| NITPICK: `get_person/2` spec | **FIXED** | `any()` removed in `2245c30` |
| NITPICK: Module doc stale | **FIXED** | Updated in `2245c30` |

## New findings

### IMPROVEMENT - MEDIUM: Context write functions still accept trashed people

**Severity:** IMPROVEMENT - MEDIUM (elevated from Kimi's flagged item)

**Finding:** The soft-delete hardening is inconsistent. Two context entry points
that create relationships will accept a trashed `staff_person_uuid`:

- `PhoenixKitStaff.Staff.Memberships.add_team_person/2`
- `PhoenixKitStaff.Skills.assign_skill/3`

The UI pickers (`people_not_on_team/1`, `people_without_skill/1`) already exclude
trashed people, so this is only reachable via direct API calls. However, the
rest of the soft-delete implementation is meticulously hardened:

- `Person.changeset/2` rejects `status: "trashed"` from params
- `trash_person/1` / `restore_person/1` / `delete_person/1` have strict guards
- Bulk operations (`bulk_trash`, `bulk_restore`, `bulk_delete`) are trash-only
- `create_person/1` returns `{:error, {:trashed_person_exists, person}}`
- Every list/roster query excludes trashed by default

Allowing new memberships/assignments to trashed people breaks this consistency.
A trashed person is meant to be "deleted" from an application perspective —
creating new relationships with them undermines the soft-delete abstraction.

**Impact:** 
- Low **practical** risk: UI prevents it; only API consumers could trigger
- High **architectural** risk: Inconsistency in the soft-delete contract

**Evidence:**
```elixir
# Current behavior — both succeed even with trashed person_uuid
Skills.assign_skill(trashed_person.uuid, skill.uuid, [])
# => {:ok, %PersonSkill{}}

Staff.add_team_person(team.uuid, trashed_person.uuid)
# => {:ok, %TeamMembership{}}
```

The existing integration test at
`test/phoenix_kit_staff/integration/skills_test.exs:87` even demonstrates
assigning to a person *before* trashing them, which succeeds. This is the
behavior that should be blocked.

**Recommended fix:**

Add a guard at the top of each function:

```elixir
# In lib/phoenix_kit_staff/skills.ex
def assign_skill(person_uuid, skill_uuid, level_ids \ []) do
  if get_person(person_uuid)&.status == @soft_delete_status do
    {:error, :person_trashed}
  else
    # ... existing transaction logic
  end
end

# In lib/phoenix_kit_staff/staff/memberships.ex  
def add_team_person(team_uuid, staff_person_uuid) do
  if get_person(staff_person_uuid)&.status == @soft_delete_status do
    {:error, :person_trashed}
  else
    # ... existing logic
  end
end
```

**Files:**
- `lib/phoenix_kit_staff/skills.ex`
- `lib/phoenix_kit_staff/staff/memberships.ex`

**Test additions needed:**
```elixir
# In test/phoenix_kit_staff/integration/skills_test.exs
test "assign_skill/3 rejects a trashed person" do
  skill = fixture_skill()
  trashed = fixture_person()
  {:ok, _} = Staff.trash_person(trashed)
  assert {:error, :person_trashed} = Skills.assign_skill(trashed.uuid, skill.uuid, [])
end

# In test/phoenix_kit_staff/integration/staff_queries_test.exs
test "add_team_person/2 rejects a trashed person" do
  team = fixture_team()
  trashed = fixture_person()
  {:ok, _} = Staff.trash_person(trashed)
  assert {:error, :person_trashed} = Staff.add_team_person(team.uuid, trashed.uuid)
end
```

## Summary

| Category | Count |
|----------|-------|
| Prior findings verified fixed | 8 |
| Prior findings still open | 1 |
| New findings | 1 (elevated from prior open item) |

**Bottom line:** PR #10 and its follow-up commits are high quality. The one
outstanding gap — context write functions not guarding against trashed people
— is a real architectural inconsistency that should be addressed for completeness.
All other findings were properly remediated with tests.
