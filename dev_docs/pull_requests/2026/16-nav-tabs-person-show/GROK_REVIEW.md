# Grok Review — PR #16 "Remove the local TabsStrip in favour of core's nav_tabs, and fix the daisyUI tabs class"

**Merge commit:** fc91c8b
**Author:** mdon (fix/daisyui-tabs-box)
**Files:** `lib/phoenix_kit_staff/web/components/tabs_strip.ex` (deleted), `lib/phoenix_kit_staff/web/person_show_live.ex`

## Summary of the change

`TabsStrip` was a module-local copy of core's event-mode `<.nav_tabs>`,
down to the `phx-value-tab` payload. Its own docstring flagged it as "a
candidate for promotion to core once a third module needs it" — that
third case already existed. The component is deleted; `PersonShowLive`
renders `<.nav_tabs>` and `tab_list/2` now returns maps (`:id` / `:label`
/ `:icon`) instead of `{value, label, icon}` tuples. `valid_tabs/2`
reads `& &1.id`. `handle_event("switch_tab", %{"tab" => tab}, _)` was
already the right shape.

No remaining `TabsStrip` / `tabs_strip` references in lib or tests.

## Findings

None.
