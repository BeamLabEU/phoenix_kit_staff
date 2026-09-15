# Follow-up — PR #19

Resolution of the findings in `CLAUDE_REVIEW.md`, shipped in 0.8.5.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | BUG - MEDIUM | Read and purge paths resolve the folder with a different hook answer than create (lost media, twin folders, orphaned media on purge) | Fixed: name-based `find_root_folder/2` (configured parent, then root, then any parent); purge deletes every `staff-person-<uuid>` folder; component passes the actor |
| 2 | IMPROVEMENT - MEDIUM | Hook `subject` always `nil` | Fixed: the person uuid is passed |
| 3 | NITPICK | Hook `:exit` not caught | Fixed: `catch :exit` falls back to root |
| 4 | NITPICK | Moduledoc mentions a nonexistent avatar check | Fixed: doc rewritten |
| 5 | NITPICK | DB-backed test in the unit dir | Fixed: moved to `integration/` and extended (9 tests) |
| 6 | NITPICK | Hook runs on every media-tab update | Not fixed: documented as host responsibility (the hook should be a cheap lookup) |
| — | pre-existing | Lookups ignore `Folder.trashed_at` | Not fixed: out of scope, on record |
