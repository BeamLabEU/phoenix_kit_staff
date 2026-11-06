# PhoenixKitStaff

A [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) plugin that adds **departments**, **teams**, and **staff profiles** to a Phoenix app. Each staff profile is linked 1:1 to a PhoenixKit user; people not yet in your system can be added via a placeholder user that auto-links when they later register or sign in via OAuth.

## Features

- Departments and teams with cascading deletes
- Staff profiles with birthdays and emergency contacts; personal fields are
  gated behind the `staff.view_personal` permission
- Employment history: dated spans per person, one open at a time, mirrored onto
  the profile
- Skills — a translatable skill taxonomy with **optional, named selectors** (each
  skill defines its own, single- or multi-select), assigned to people many-to-many
- Translations of names and descriptions, edited per language in the forms
- Files, images and an avatar per person, on core Storage folders
- A comment thread per person (`phoenix_kit_comments`)
- People are trashed and restored; a permanent delete also removes their media
- Org tree view (departments → teams → people)
- Upcoming-birthdays widget
- Placeholder-user flow for inviting people who don't yet have an account
- Real-time updates via `PhoenixKit.PubSub.Manager`
- Activity logging for every mutation
- Admin pages under `/admin/staff/*`

## Installation

Add to your parent PhoenixKit app's `mix.exs`:

```elixir
{:phoenix_kit_staff, "~> 0.11"}
# or, from a local checkout:
{:phoenix_kit_staff, path: "../phoenix_kit_staff"}
```

Also add `:phoenix_kit_staff` to `extra_applications` so `PhoenixKit.ModuleDiscovery` finds it:

```elixir
def application do
  [extra_applications: [:logger, :phoenix_kit, :phoenix_kit_staff]]
end
```

Run `mix deps.get` and `mix phoenix_kit.update`, then toggle the module on from
**Admin > Modules**.

## Database

This module owns its tables: its migration chain is `PhoenixKitStaff.Migrations`,
which the parent app runs with `mix phoenix_kit.install` / `mix phoenix_kit.update`,
after core's. V1 adopts the tables core 2.x created and builds them where core 3.x
no longer does. Changes to them ship here, never in core.

Tables:

- `phoenix_kit_staff_departments`
- `phoenix_kit_staff_teams` (FK → departments, cascading delete)
- `phoenix_kit_staff_people` (FK → `phoenix_kit_users`, cascading delete)
- `phoenix_kit_staff_team_memberships` (join table)
- `phoenix_kit_staff_skills` (translatable; its selectors are the `levels` JSONB)
- `phoenix_kit_staff_person_skills` (person ↔ skill join; `proficiency_levels` is a
  JSONB array of the selected option ids)
- `phoenix_kit_staff_employments` (a person's employment spans)

All tables use UUIDv7 primary keys.

## Public API

```elixir
# Departments
PhoenixKitStaff.Departments.list/1
PhoenixKitStaff.Departments.get/1
PhoenixKitStaff.Departments.create/1
PhoenixKitStaff.Departments.update/2
PhoenixKitStaff.Departments.delete/1

# Teams
PhoenixKitStaff.Teams.list/1        # accepts :department_uuid filter
PhoenixKitStaff.Teams.create/1      # requires department_uuid

# Staff (people + team memberships + org tree)
PhoenixKitStaff.Staff.list_people/1
PhoenixKitStaff.Staff.get_person/1
PhoenixKitStaff.Staff.get_person_by_user_uuid/2
PhoenixKitStaff.Staff.create_person/1
PhoenixKitStaff.Staff.create_person_with_user/2  # find-or-create placeholder user
PhoenixKitStaff.Staff.org_tree/0
PhoenixKitStaff.Staff.upcoming_birthdays/1
PhoenixKitStaff.Staff.add_team_person/2
PhoenixKitStaff.Staff.remove_team_person/2

# Skills (taxonomy + selectors + assignment)
PhoenixKitStaff.Skills.list/1
PhoenixKitStaff.Skills.create/1                  # accepts levels (the selectors)
PhoenixKitStaff.Skills.update/2                  # reconciles assignments on selector changes
PhoenixKitStaff.Skills.assign_skill/3            # (person_uuid, skill_uuid, option_ids)
PhoenixKitStaff.Skills.update_assignment_levels/2
PhoenixKitStaff.Skills.list_for_person/1
PhoenixKitStaff.Skills.list_people_for_skill/1

# Employment history (one open span per person)
PhoenixKitStaff.Employments.list_for_person/1
PhoenixKitStaff.Employments.create/2             # closes the prior open span
PhoenixKitStaff.Employments.update/2
```

## Consumed by other plugins

`phoenix_kit_projects` has foreign keys into these tables and reads them through its own schemas, so their columns are part of the contract too; it calls `enabled?/0`, the `Paths` helpers and `Staff.create_person/1`. `phoenix_kit_crm` links a contact to a person through `enabled?/0`, `Paths.person/1`, `Staff.list_people/1`, `Staff.get_person/1`, `Staff.get_person_by_user_uuid/2` and `Schemas.Person.display_name/1`. Keep these stable; `AGENTS.md` has the full contract.

## Development

See [`AGENTS.md`](AGENTS.md) for development conventions, test setup, and the pre-commit workflow.

## License

MIT
