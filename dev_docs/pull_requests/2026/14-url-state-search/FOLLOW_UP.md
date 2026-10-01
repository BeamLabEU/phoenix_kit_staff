# Follow-up Items for PR #14

Triaged against `main` on 2026-10-01. Findings from `CLAUDE_REVIEW.md`,
checked against the current code (including the 2026-09-30/10-01 people
list toolbar rework).

## Fixed (pre-existing)

- ~~**BUG - CRITICAL** `phoenix_kit` pin admitted cores without
  `UrlState`~~ — fixed in the review commit `7e41691` (`~> 1.7.231`), and
  since superseded by the 2.x floors (`b1313d1`, then `94a1fc1`):
  `mix.exs:95` now requires `>= 2.38.0 and < 3.0.0`, well above the release
  that first shipped `PhoenixKitWeb.Live.UrlState`.
- ~~**IMPROVEMENT - HIGH** URL-state behaviour shipped with no tests~~ —
  fixed in `7e41691`. `test/phoenix_kit_staff/web/people_live_url_state_test.exs`
  holds the 9 codec tests (the whitelist-vs-`Person.statuses/0` drift check
  is at `:26-30`); `test/phoenix_kit_staff/web/listing_lvs_test.exs:194-240`
  holds the LiveView tests (shared `?q=` link, `?status=trashed`, crafted
  status, status change patches the URL, Clear).
- ~~**NITPICK** Mis-indented HEEx form-recovery comment~~ — fixed in
  `7e41691`; after the toolbar rework the comment sits at
  `lib/phoenix_kit_staff/web/people_live.ex:293-294`, aligned with the
  `<.form>` it describes.
- ~~Out-of-scope: eight stale `mix.lock` entries broke
  `deps.unlock --check-unused`~~ — pruned in `7e41691`; none of `ex_ast`,
  `glob_ex`, `igniter`, `owl`, `rewrite`, `sourceror`, `spitfire`,
  `text_diff` is a top-level entry in the current `mix.lock`.

## Files touched

None — documentation only.

## Verification

- Read `CLAUDE_REVIEW.md` in full, including "Considered and NOT changed".
- Read the current `people_live.ex` (UrlState spec `:13-16`,
  `handle_url_state/2` `:48`, `handle_params/3` no-op `:53`, filter event
  `:79-87`), `mix.exs`, `mix.lock` and the two test files.
- No code was compiled or run for this triage.

## Open

Awaiting Max's decision (fix now, skip, or separate PR). Both are
suggestions the reviewer considered and recommended against; they remain
as described:

- **LOW** — `dead_render: :skip` not used —
  `lib/phoenix_kit_staff/web/people_live.ex:13-16`. Would halve the people
  queries per page load, but the template would have to tolerate `@people`
  / `@trashed_count` being unset and the list would flash empty on load.
  Reviewer: not worth it.
- **LOW** — `replace:` heuristic names the search box rather than the
  status select — `lib/phoenix_kit_staff/web/people_live.ex:86`
  (`replace: params["_target"] == ["search"]`). Inverting it to
  `!= ["status"]` is slightly more robust for a reconnect whose first
  input is not the search box, but a future third filter would then not get
  its own history entry. Reviewer: keep as is.
