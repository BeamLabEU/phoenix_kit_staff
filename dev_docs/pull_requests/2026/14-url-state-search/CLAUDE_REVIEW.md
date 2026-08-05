# Claude Review — PR #14

PR: **Put the staff list search and status filter in the URL (#14)**
Author: Timujeen
Merge commit: `510c07f` (commits `2521fb8`, `d4b31b0`)
Review-fix commit: this commit (Co-Authored-By: Claude Opus 5)

Post-merge review of PR #14. The PR moves `PeopleLive`'s search box and status
dropdown into the query string via core's `PhoenixKitWeb.Live.UrlState`, so a
filtered list becomes a real URL — shareable, reload-proof, and Back-able.

The LiveView-side work is correct and, unusually for a URL-state adoption,
gets the awkward parts right. Verified against core's
`lib/phoenix_kit_web/live/url_state.ex` at `phoenix_kit 1.7.231`:

- **The data load moved out of `mount/3`.** `mount/3` now only subscribes and
  seeds non-URL assigns; `handle_url_state/2` owns `load_people/1`. Core's
  `on_mount` hook assigns the decoded params *before* `mount/3` runs, and the
  `:handle_params` hook calls the callback after it, so the first render, a
  shared link and a Back press all take one code path. This is the correct
  shape (`mount/3` is called twice; `handle_params` is not).
- **The explicit `handle_params/3` no-op is required, not redundant.** Core's
  `__before_compile__` only injects a stub when the module doesn't define one,
  and the injected stub carries no `@impl`. Since this module annotates every
  callback, letting the stub be injected would be a warning — and
  `mix precommit` compiles warnings as errors. Core's own docs prescribe
  exactly what the PR did.
- **The `replace:` heuristic is right.** `push_url_state(..., replace: params["_target"] == ["search"])` collapses debounced typing into one history entry while a status pick earns a real one. Form recovery is safe too: LiveView's
  `pushFormRecovery` sends `_target: input.name` for the first non-hidden input
  — here the search box — so a reconnect replaces rather than piling up a
  bogus entry.
- **The status whitelist is genuinely in sync** with the three lists it has to
  match: the `<.select>` `options` in the render, `Staff.scope_status/3`, and
  `Person.statuses/0` + `Person.soft_delete_status/0`. The PR's comment about
  `"trashed"` deliberately living outside `Person.statuses/0` is accurate.
- **Crafted input is safe.** `?status=…` is interpolated into
  `scope_status/3`'s `where`, but core's decoder rejects anything outside `:in`
  before it lands in the assign, and `sanitize/2` re-checks on the write path.

One release-blocking packaging bug was found and fixed; the rest is test
coverage the PR shipped without.

---

## BUG - CRITICAL: `phoenix_kit` pin allows versions without `UrlState`, so the published package would not compile

**Finding:** `PeopleLive` now compiles against `PhoenixKitWeb.Live.UrlState`,
a **compile-time** dependency (`use PhoenixKitWeb.Live.UrlState, params: […]`).
That module first shipped in core **1.7.231**:

```
$ cd ../phoenix_kit
$ git log --diff-filter=A --date=short --format="%h %ad %s" -- lib/phoenix_kit_web/live/url_state.ex
ae9164c 2026-08-04 Add UrlState: URL-backed search, filter and page state for list LiveViews
$ for t in v1.7.228 v1.7.229 v1.7.230 v1.7.231; do
    printf "%s: " $t
    git cat-file -e "$t:lib/phoenix_kit_web/live/url_state.ex" 2>/dev/null && echo HAS || echo missing
  done
v1.7.228: missing
v1.7.229: missing
v1.7.230: missing
v1.7.231: HAS
```

`mix.exs` still declared `pk_dep(:phoenix_kit, "~> 1.7.189")`, which resolves
anything in `>= 1.7.189 and < 1.8.0`. Nothing else in the tree forces a floor
above that — `phoenix_kit_comments 0.2.15` also asks only for `~> 1.7.189`.

Effect: any consumer whose lock (or fresh resolution) lands on
`phoenix_kit` 1.7.189–1.7.230 gets

```
** (CompileError) lib/phoenix_kit_staff/web/people_live.ex:13:
   module PhoenixKitWeb.Live.UrlState is not available
```

i.e. a published package that cannot be compiled. This repo's own `mix.lock`
happens to hold 1.7.231, which is why CI stayed green — the lockfile masks the
constraint. The project has raised this floor deliberately on every prior
release that consumed a new core feature (`>= 1.7.132` for `metadata` JSONB,
`>= 1.7.159` for V136 / `Activity.list` `resource_uuid`); PR #14 consumed one
and did not.

**Fix:** raised the pin to `~> 1.7.231`, with the reason recorded at the call
site, and stated the requirement in the CHANGELOG entry per the repo's
convention.

```elixir
# `~> 1.7.231` — `PeopleLive` compiles against `PhoenixKitWeb.Live.UrlState`,
# which core first shipped in 1.7.231. A looser pin lets Hex resolve a core
# without that module and the package fails to compile at the `use` site.
pk_dep(:phoenix_kit, "~> 1.7.231"),
```

---

## IMPROVEMENT - HIGH: the URL-state behaviour shipped with no tests

**Finding:** the PR changed how the staff list decides what to show — the
query string is now the source of truth — and added zero tests. Nothing pinned
that `?q=` reaches the search assign, that `?status=` is whitelisted, or that
a filter change writes the address bar. The pre-existing filter tests in
`coverage_test.exs` still pass because they assert on rendered rows, so they
would not have caught a spec that silently stopped decoding.

The status whitelist is the sharpest edge: it is a hardcoded list that has to
agree with two other hardcoded lists (the `<.select>` options and
`Staff.scope_status/3`) plus `Person.statuses/0`. Nothing enforced that.

**Fix:** two layers.

1. `test/phoenix_kit_staff/web/people_live_url_state_test.exs` — **9 tests, no
   database**, driving the spec and core's codec directly through
   `PeopleLive.__phoenix_kit_url_state__/0`. These run even where the
   integration suite is excluded, which is where a drifting whitelist would
   otherwise go unnoticed. Covers: `search` is published as `?q=`; the status
   whitelist equals `["", Person.soft_delete_status() | Person.statuses()]`;
   decode of a shared link, a bare path, the trash view, and four crafted
   status values; encode omitting defaults and preserving unrelated query keys.
2. `listing_lvs_test.exs` — **5 LiveView tests** for the end-to-end claims: a
   `?q=` link mounts an already-filtered list, `?status=trashed` mounts the
   trash view, a crafted status mounts unfiltered without killing the LV,
   changing the status patches `status=inactive` into the URL, and Clear
   patches back to the bare path.

**Note on the whitelist test:** it asserts the hardcoded list against
`Person.statuses/0` rather than making the code derive it. Deriving would be
*worse*: a status added to `Person.statuses/0` without a matching
`scope_status/3` clause would then be accepted into the URL and fall through to
the catch-all clause, silently ignoring the filter instead of failing. A
hardcoded list plus a test that goes red on drift is the safer arrangement, and
the reasoning is recorded in the test.

---

## NITPICK: mis-indented HEEX comment

`d4b31b0` added the form-recovery comment at column 5 while its siblings sit at
column 9. `mix format` does not normalise HEEX comment indentation, so it
survived the gate. Re-indented to match the block.

---

## Considered and NOT changed

- **`dead_render: :skip`.** Core offers it to halve the queries per page load
  by skipping the callback on the disconnected render. Not applied: the default
  `:call` reproduces exactly what the old `mount/3` did, so the PR is not a
  regression, and `:skip` would require the template to tolerate `@people` /
  `@trashed_count` being unset (core's docs warn the dead render raises
  otherwise) in exchange for a visible empty-then-populated flash on an
  admin-only page. Not worth the failure mode.
- **Inverting the `replace:` heuristic** to `params["_target"] != ["status"]`.
  Marginally more robust for a reconnect whose first non-hidden input is not
  the search box, but strictly worse for extension: a third filter control
  added later should push a real history entry, and the current form gets that
  right by naming the one continuous input rather than the one discrete one.

---

## Out of scope, fixed to get the gate green

`mix precommit` was already failing on `main` before this review, at the
`deps.unlock --check-unused` step: commit `38dab96` ("lib upgrades") left eight
stale entries in `mix.lock` (`ex_ast`, `glob_ex`, `igniter`, `owl`, `rewrite`,
`sourceror`, `spitfire`, `text_diff` — `igniter` is an *optional* dep of core
and its transitive closure). Pruned with `mix deps.unlock --unused`.

---

## Validation

`mix precommit` clean: `compile --force --warnings-as-errors`,
`deps.unlock --check-unused`, `hex.audit`, `format --check-formatted`,
`credo --strict` (833 mods/funs, no issues), `dialyzer` (2 errors, both
skipped by `.dialyzer_ignore.exs`).

`mix test --exclude integration` — **137 tests, 0 failures** (was 128; the 9
new codec tests run here).

⚠ **The 5 new LiveView tests were not executed.** No PostgreSQL server exists
in the review environment, so the 384 database-backed tests — the integration
suite and every `LiveCase` test, including the ones added here — were excluded
by `test_helper.exs`'s reachability check. They are written against the
existing `listing_lvs_test.exs` patterns and run in CI, which has a database.
