# PhoenixKitStaff

A [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) plugin that adds **departments**, **teams**, and **staff profiles** to a Phoenix app. Each staff profile is linked 1:1 to a PhoenixKit user; people not yet in your system can be added via a placeholder user that auto-links when they later register or sign in via OAuth.

## Features

- Departments and teams with cascading deletes
- Staff profiles with employment metadata, skills, birthdays, emergency contacts
- Org tree view (departments → teams → people)
- Upcoming-birthdays widget
- Placeholder-user flow for inviting people who don't yet have an account
- Real-time updates via `PhoenixKit.PubSub.Manager`
- Activity logging for every mutation
- Admin pages under `/admin/staff/*`

## Installation

Add to your parent PhoenixKit app's `mix.exs`:

```elixir
{:phoenix_kit_staff, path: "../phoenix_kit_staff"}
# or, once published to Hex:
{:phoenix_kit_staff, "~> 0.1"}
```

Also add `:phoenix_kit_staff` to `extra_applications` so `PhoenixKit.ModuleDiscovery` finds it:

```elixir
def application do
  [extra_applications: [:logger, :phoenix_kit, :phoenix_kit_staff]]
end
```

Run `mix deps.get`, then toggle the module on from **Admin > Modules**.

## Database

Tables are created by the **V100** versioned migration inside `phoenix_kit` core. The parent app runs migrations via `mix phoenix_kit.install` / `mix phoenix_kit.update`.

Tables created:

- `phoenix_kit_staff_departments`
- `phoenix_kit_staff_teams` (FK → departments, cascading delete)
- `phoenix_kit_staff_people` (FK → `phoenix_kit_users`, cascading delete)
- `phoenix_kit_staff_team_memberships` (join table)

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
PhoenixKitStaff.Staff.get_person_by_user_uuid/2
PhoenixKitStaff.Staff.create_person_with_user/2  # find-or-create placeholder user
PhoenixKitStaff.Staff.org_tree/0
PhoenixKitStaff.Staff.upcoming_birthdays/1
PhoenixKitStaff.Staff.add_team_person/2
PhoenixKitStaff.Staff.remove_team_person/2
```

## Consumed by other plugins

`phoenix_kit_projects` uses `list_people/1`, `get_person_by_user_uuid/2`, `Teams.list/1`, and `Departments.list/1` for assignee pickers. Keep the public API stable.

## Development

See [`AGENTS.md`](AGENTS.md) for development conventions, test setup, and the pre-commit workflow.

## License

MIT
