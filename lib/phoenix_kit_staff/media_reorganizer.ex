defmodule PhoenixKitStaff.MediaReorganizer do
  @moduledoc """
  Staff's media-reorganizer plan source.

  Not compiled against a core `PhoenixKit.Modules.Storage.Reorganizer.Source`
  behaviour — today's hex core (2.23.x) does not ship the engine yet. This
  module declares no `@behaviour` and returns plain maps; see
  `PhoenixKitStaff.media_reorganizer/0` for the registration comment.
  Once core ships the engine, `plan/2`'s contract (`plan(actor_uuid, opts)
  :: [map()]`) already matches `Source.plan/2` — the only follow-up is
  adding `@behaviour`/`@impl`.

  Contract (design §9/§10/§11 of `2026-09-15-media-reorganizer-design.md`):

    * **No configured `:attachments_parent_folder` hook → `:report`-only.**
      Orphan reports are still produced (informational, no writes); no
      `:move`, no `:trash`, no pointer back-fill (staff writes no pointer
      at all — see below). A `{mod, fun}` that IS configured but not
      actually callable (typo, removed function) is a distinct failure
      (`kind: :hook_error`, "not callable") from "no hook configured at
      all" — it does not silently degrade to report-only without saying
      why nothing moved.
    * **A hook that raises, exits, or returns anything but `{:ok, uuid}` or
      an explicit `nil`** is a hook FAILURE: the record is skipped (no
      move planned for it) and counted into one `kind: :hook_error` report
      for the whole plan. Only an explicit `nil`/`{:ok, nil}` means "root".
      Every `{:ok, answer}` is cast through `Ecto.UUID.cast/1` and
      downcased first — a garbage answer (`{:ok, ""}`, `{:ok, "x"}`) is a
      failure too, never sent into a later query.
    * **`nil` never moves a folder that is already parented.** When the
      hook answers root but a candidate's only live folder sits under some
      other parent, that folder is adopted in place (no move) and counted
      into one `kind: :hook_nil` report — distinct from `:relocated`,
      which is for a real (non-nil) hook answer that simply doesn't match
      where the folder lives.
    * **Current-folder lookup**: the legacy deterministic name looked up
      under the resolved parent first, then at root — never anywhere
      else. Staff has no folder-name hook — a person's folder name is
      always `staff-person-<uuid>` (`Attachments.root_folder_name/1`) —
      and **no cached folder pointer**, so a plan never needs an
      `after_move` back-fill and a `:move` action never uses
      `on_conflict: :suffix`: renaming a pointer-less folder on conflict
      would orphan it (nothing could ever find it again by its new name).
      Conflicting moves are reported instead (`on_conflict: :report`).
    * **A legacy folder live at both root and under the resolved parent**
      is unresolvable — reported `kind: :duplicate` naming both folders,
      nothing moved.
    * **Every live legacy-named copy other than a person's adopted current
      folder** gets its own `kind: :relocated` report — all of them, not
      only the first — except a copy that is itself another candidate's
      own adopted folder, which is never also reported `:relocated`.
      Staff's parent hook receives the acting user, so the report says
      the answer may depend on which user resolves it (E6).
    * Only a person with SOME live folder already (anywhere, matching
      their deterministic name) is a *candidate* — a person with no
      folder at all never triggers a (possibly writing) host hook, and
      the hook is never called once per plan either, only once per actual
      candidate (R8 — no subject-less per-plan call).

  Covers each live `Person`'s root attachment folder (the nested `Images`
  subfolder travels with it — it's a child of the root by `parent_uuid`, not
  moved separately) and orphaned legacy folders whose record is gone or
  trashed (reported, never moved/trashed — see "Orphaned legacy folders"
  below). Staff has no pending-upload folder prefix to reorganize.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
  alias PhoenixKitStaff.Attachments
  alias PhoenixKitStaff.Schemas.Person

  @legacy_prefix "staff-person-"

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds staff's reorganizer plan: one `:move` action per live person whose
  current folder does not already sit at the hook-resolved parent under its
  deterministic name, a `:report` (`kind: :duplicate`) per person whose
  legacy folder is live in both places at once, a `:report`
  (`kind: :relocated`) per live legacy-named copy other than a person's
  adopted current folder, a `:report` (`kind: :hook_error`) counting every
  candidate the configured hook failed (or wasn't callable) for, a
  `:report` (`kind: :hook_nil`) counting every candidate whose parented
  folder was left in place because the hook answered root, and a `:report`
  (`kind: :orphan`) per legacy folder whose record is missing or trashed.

  `opts` is accepted for parity with the `Source.plan/2` contract; staff has
  no pending-folder rules to tune, so nothing in it is read.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    {resource_actions, resolved_parents} =
      case hook_status() do
        {:ok, mod, fun} ->
          build_resource_plan(light_people(), actor_uuid, mod, fun)

        {:not_callable, mod, fun} ->
          {[not_callable_hook_action(mod, fun)], []}

        :none ->
          {[], []}
      end

    resource_actions ++ orphan_actions(resolved_parents)
  end

  # ── People ───────────────────────────────────────────────────────

  # T3: a configured `{mod, fun}` that is not actually callable (a typo, a
  # removed function) is a distinct failure from "no hook configured at
  # all" — it must not silently degrade to report-only (E1) without
  # telling the owner why nothing moved.
  defp hook_status do
    case Application.get_env(:phoenix_kit_staff, :attachments_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        if callable?(mod, fun), do: {:ok, mod, fun}, else: {:not_callable, mod, fun}

      _ ->
        :none
    end
  end

  defp callable?(mod, fun) do
    Code.ensure_loaded?(mod) and
      (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2))
  end

  defp not_callable_hook_action(mod, fun) do
    %{
      source: "staff",
      kind: :hook_error,
      op: :report,
      label: "attachments parent hook",
      counts: nil,
      reason: "configured parent hook {#{inspect(mod)}, #{inspect(fun)}} is not callable"
    }
  end

  # Candidate detection needs no hook call: a live folder anywhere named
  # after the person's legacy name. Only candidates go on to have the
  # host's parent hook resolved — a person with nothing pointing at them
  # never triggers a (possibly writing) host hook, and there is no other,
  # subject-less call to resolve a parent for orphans in the absence of any
  # candidate (R8) — a host with zero candidate people is left untouched
  # beyond root-level orphan detection.
  defp build_resource_plan(people, actor_uuid, mod, fun) do
    prelim =
      Enum.map(people, fn person ->
        %{record: person, name: Attachments.root_folder_name(person.uuid)}
      end)

    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.name))

    candidates = Enum.filter(prelim, &Map.has_key?(by_name, &1.name))

    {resolved_candidates, hook_error_count} = resolve_candidates(candidates, mod, fun, actor_uuid)

    entries =
      resolved_candidates
      |> Enum.map(&resolve_entry(&1, by_name))
      |> Enum.map(&apply_nil_root_guard/1)

    # NEW-10: parents are taken from EVERY candidate the hook resolved a
    # parent for, not only the ones that ended up with a chosen current
    # folder — an orphan under a parent must still be found even when the
    # only candidate resolving to it went `:relocated` (its own folder
    # lives somewhere else entirely).
    resolved_parents =
      entries |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, without_folder} = Enum.split_with(normal, & &1.folder)

    move_actions = with_folder |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    dup_actions = Enum.map(ambiguous, &build_duplicate_action/1)
    hook_error_actions = hook_error_action(hook_error_count)
    hook_nil_actions = hook_nil_action(Enum.count(entries, & &1.hook_nil))

    claimed = claimed_folder_uuids(with_folder, ambiguous)

    # F5/T5: every live legacy-named copy other than a record's adopted
    # current folder gets its own `:relocated` report — all of them, not
    # just the first — except a copy that is itself another record's
    # claimed (adopted) folder, which is never also reported `:relocated`.
    stray_actions =
      Enum.flat_map(with_folder ++ without_folder, &stray_relocated_actions(&1, claimed))

    all_actions =
      move_actions ++ dup_actions ++ stray_actions ++ hook_error_actions ++ hook_nil_actions

    {finalize_counts(all_actions), resolved_parents}
  end

  # R2: resolves the desired parent for every candidate via the host's
  # exact hook, distinguishing an explicit `nil` (root) from a hook that
  # raised/exited/returned anything else (failure — the candidate is
  # dropped from `entries` and counted in `hook_error_count`, never
  # treated as "root").
  defp resolve_candidates(candidates, mod, fun, actor_uuid) do
    {entries, hook_error_count} =
      Enum.reduce(candidates, {[], 0}, fn c, {acc, errs} ->
        case resolve_parent(mod, fun, actor_uuid, c.record.uuid) do
          {:ok, parent_uuid} -> {[Map.put(c, :parent_uuid, parent_uuid) | acc], errs}
          :error -> {acc, errs + 1}
        end
      end)

    {Enum.reverse(entries), hook_error_count}
  end

  # T3: `build_resource_plan/4` is only reached once `hook_status/0` has
  # already confirmed one of the two arities is exported on a loaded
  # module — there is no third "not callable" outcome left to handle here.
  defp resolve_parent(mod, fun, actor_uuid, person_uuid) do
    if function_exported?(mod, fun, 3) do
      guarded_hook_call(fn -> apply(mod, fun, [:person, actor_uuid, person_uuid]) end)
    else
      guarded_hook_call(fn -> apply(mod, fun, [:person, actor_uuid]) end)
    end
  end

  # T1: every answer is cast through `Ecto.UUID.cast/1` and downcased —
  # `{:ok, ""}` / `{:ok, "not-a-uuid"}` are hook FAILURES (`:error`), never
  # sent into a later `in ^uuids` query (which would raise a CastError and
  # take down the whole plan). F2: an explicit `{:ok, nil}` or bare `nil`
  # means root. T4: an exception is logged (not just swallowed) with the
  # module/function it came from.
  defp guarded_hook_call(fun) do
    case fun.() do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, uuid} ->
        case valid_uuid(uuid) do
          nil -> :error
          cast -> {:ok, cast}
        end

      nil ->
        {:ok, nil}

      _other ->
        :error
    end
  rescue
    error ->
      Logger.warning(
        "Attachments parent hook raised: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    kind, reason ->
      Logger.warning("Attachments parent hook #{kind}: #{inspect(reason)}")
      :error
  end

  # Resolves one person's current folder: the legacy name looked up under
  # the resolved parent first, then at root (module's own order — X9: only
  # these two places, never "anywhere else" the folder might have been
  # moved to). A live match at both is ambiguous (X11). A candidate always
  # has at least one live match somewhere (that's what made it a candidate
  # in the first place) — when neither the resolved parent nor root has
  # one, every remaining live match becomes a stray copy: a lone stray is
  # left to `apply_nil_root_guard/1` (which turns it into the adopted
  # folder when the hook explicitly said root) or reported `:relocated`
  # otherwise; two or more are unresolvable the same way root+parent is —
  # one `:duplicate` naming every copy, not the first match with the rest
  # silently dropped.
  defp resolve_entry(d, by_name) do
    matches = Map.get(by_name, d.name, [])
    under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
    at_root = Enum.find(matches, &is_nil(&1.parent_uuid))

    resolve_entry_result(d, matches, under_parent, at_root)
  end

  defp resolve_entry_result(d, _matches, under_parent, at_root)
       when not is_nil(under_parent) and not is_nil(at_root) do
    Map.merge(d, %{folder: nil, ambiguous: [under_parent, at_root], stray_legacy: []})
  end

  defp resolve_entry_result(d, matches, under_parent, nil) when not is_nil(under_parent) do
    Map.merge(d, %{
      folder: under_parent,
      ambiguous: nil,
      stray_legacy: stray(matches, under_parent)
    })
  end

  defp resolve_entry_result(d, matches, nil, at_root) when not is_nil(at_root) do
    Map.merge(d, %{folder: at_root, ambiguous: nil, stray_legacy: stray(matches, at_root)})
  end

  defp resolve_entry_result(d, [only], nil, nil) do
    Map.merge(d, %{folder: nil, ambiguous: nil, stray_legacy: [only]})
  end

  defp resolve_entry_result(d, matches, nil, nil) do
    Map.merge(d, %{folder: nil, ambiguous: matches, stray_legacy: []})
  end

  defp stray(matches, chosen), do: Enum.reject(matches, &(&1.uuid == chosen.uuid))

  # F1: an explicit `nil`/`{:ok, nil}` hook answer never pulls a folder
  # that currently lives under a real parent out to root. When the hook
  # said root and the only thing this candidate resolved to is a single
  # stray match (a folder living under some other parent, not root), that
  # folder IS adopted as-is (no move, no rename) and counted into one
  # `:hook_nil` report instead of `:relocated` — `:relocated` stays for
  # the case where the hook answered a REAL parent that simply doesn't
  # match where the folder lives (the owner moved it, or it predates a
  # parent-hook change).
  defp apply_nil_root_guard(%{parent_uuid: nil, folder: nil, stray_legacy: [only]} = entry) do
    Map.merge(entry, %{
      folder: only,
      parent_uuid: only.parent_uuid,
      stray_legacy: [],
      hook_nil: true
    })
  end

  defp apply_nil_root_guard(entry), do: Map.put(entry, :hook_nil, false)

  # A `:move` whose folder already sits at `parent_uuid` under `name` is
  # filtered out here as a no-op before it ever reaches the engine.
  # `on_conflict: :report` (D3, X8): staff writes no pointer, so a folder
  # the engine renamed on a name conflict would be permanently orphaned —
  # nothing could resolve it by name again.
  defp build_move_action(%{record: person, folder: folder, parent_uuid: parent_uuid, name: name}) do
    if noop_move?(folder, parent_uuid, name) do
      nil
    else
      %{
        source: "staff",
        kind: :person,
        label: label_for(person),
        op: :move,
        folder: folder,
        parent_uuid: parent_uuid,
        name: name,
        counts: nil,
        on_conflict: :report,
        after_move: nil
      }
    end
  end

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true
  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp build_duplicate_action(%{record: person, ambiguous: folders}) do
    uuids = Enum.map_join(folders, ", ", & &1.uuid)

    %{
      source: "staff",
      kind: :duplicate,
      label: label_for(person),
      op: :report,
      counts: nil,
      reason:
        "legacy folder found live in #{length(folders)} places (#{uuids}) — pick one and remove the others"
    }
  end

  defp claimed_folder_uuids(with_folder, ambiguous) do
    folder_uuids = Enum.map(with_folder, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous, fn %{ambiguous: pair} -> Enum.map(pair, & &1.uuid) end)

    MapSet.new(folder_uuids ++ ambiguous_uuids)
  end

  defp stray_relocated_actions(entry, claimed) do
    entry.stray_legacy
    |> Enum.reject(&MapSet.member?(claimed, &1.uuid))
    |> Enum.map(&build_relocated_action(%{record: entry.record, relocated: &1}))
  end

  # A legacy folder that is live but neither at root nor under the
  # resolved parent — the owner moved it elsewhere, or it predates a
  # parent-hook change. Left alone, never adopted or moved. E6: staff's
  # hook receives the acting user, so the report names that dependency
  # instead of implying the folder is unconditionally misplaced.
  defp build_relocated_action(%{record: person, relocated: folder}) do
    %{
      source: "staff",
      kind: :relocated,
      op: :report,
      label: label_for(person),
      folder: folder,
      counts: nil,
      reason: relocated_reason(folder)
    }
  end

  defp relocated_reason(folder) do
    "legacy folder #{folder.uuid} is live under a different parent — left alone, never " <>
      "adopted; whether it belongs there may depend on the acting user (the parent hook " <>
      "receives the actor and can resolve differently for someone else)"
  end

  defp hook_error_action(0), do: []

  defp hook_error_action(count) do
    [
      %{
        source: "staff",
        kind: :hook_error,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{count} record(s) skipped: the configured parent hook raised, exited, or " <>
            "returned neither {:ok, uuid} nor nil"
      }
    ]
  end

  # F1: a plain count, not one report per record — mirrors hook_error_action.
  defp hook_nil_action(0), do: []

  defp hook_nil_action(count) do
    [
      %{
        source: "staff",
        kind: :hook_nil,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{count} record(s): the parent hook answered root for a folder living under a " <>
            "parent — left in place"
      }
    ]
  end

  defp label_for(%{name: name, uuid: uuid}) do
    if is_binary(name) and name != "", do: name, else: uuid
  end

  # R5/X3: a pointer-less module has no pointer to normalise, but the hook
  # ANSWER still needs the same treatment — a non-UUID string must never
  # reach a later `in ^uuids` query.
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, cast} -> cast
      :error -> nil
    end
  end

  defp valid_uuid(_), do: nil

  # One query for every distinct legacy name in the batch, matching a live
  # folder ANYWHERE (any parent, including root) — not filtered to a
  # resolved parent, since the parent hook has not run yet for people
  # without another candidate folder. Grouped by name so more than one
  # live match (different parents) is visible to `resolve_entry/2` (X11).
  # Live only (X2 — the unique index is partial, a trashed twin must not
  # hide the live folder).
  defp preload_by_name_anywhere(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`staff-person-<uuid>`) at the media root or under
  # a parent this batch's hook resolved to, whose uuid no longer names a
  # live person (missing, or trashed — same status rule `light_people/0`
  # above uses to drop it from the plan) is reported so a host can collect
  # it. Never `:move`d or `:trash`ed here — staff owns no "orphans"
  # container; a legacy folder that IS a live person's current folder is
  # left to `build_move_action/1` above (a live person's own folder is
  # never reported here since its record status filters it out below).
  defp orphan_actions(resolved_parents) do
    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        people_by_uuid = load_candidate_people(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _uuid} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, people_by_uuid, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under a resolved
  # parent whose name starts with the legacy prefix. R10: ordered so the
  # resulting orphan reports come out in a deterministic, readable order.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> order_by([f], asc: f.inserted_at, asc: f.uuid)
    |> repo().all()
    |> Enum.map(&{&1, legacy_uuid(&1.name)})
    |> Enum.filter(fn {_folder, uuid} -> uuid end)
  end

  # X7: a strict UUID regex on the suffix (36-char canonical form) — not
  # `Ecto.UUID.cast/1`, which also accepts a raw 16-byte binary and would
  # key the map differently than the record's (lowercased) uuid.
  defp legacy_uuid(name) do
    suffix = String.replace_prefix(name, @legacy_prefix, "")

    if Regex.match?(@uuid_regex, suffix) do
      String.downcase(suffix)
    end
  end

  # One query for every candidate uuid — not per folder. Reads every status
  # (including "trashed") so a trashed person's folder can still be
  # reported, and the missing case is distinguished by a plain miss. R9:
  # only the columns an orphan report needs, same light select as the
  # live-people lookup above.
  defp load_candidate_people(candidates) do
    uuids = candidates |> Enum.map(fn {_folder, uuid} -> uuid end) |> Enum.uniq()

    Person
    |> where([p], p.uuid in ^uuids)
    |> select([p], struct(p, [:uuid, :name, :status, :inserted_at]))
    |> repo().all()
    |> Map.new(&{&1.uuid, &1})
  end

  defp orphan_action({folder, uuid}, people_by_uuid, counts) do
    case Map.get(people_by_uuid, uuid) do
      %{status: status} when status != "trashed" ->
        nil

      person ->
        folder_counts = folder_counts(counts, folder.uuid)

        %{
          source: "staff",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: folder_counts,
          reason: orphan_reason(person, folder_counts)
        }
    end
  end

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"

  defp orphan_reason(%{status: status}, {files, _links}),
    do: "record status #{status}, #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # X1: two grouped queries (files by folder_uuid, links by folder_uuid)
  # for the whole plan's folder set — never a query per action. Counts ALL
  # rows regardless of status (including trashed files) — the core engine
  # re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts_by_folder(folder_uuids) do
    case Enum.uniq(folder_uuids) do
      [] ->
        {%{}, %{}}

      uuids ->
        files =
          PhoenixKit.Modules.Storage.File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> select([l], {l.folder_uuid, count(l.uuid)})
          |> repo().all()
          |> Map.new()

        {files, links}
    end
  end

  defp folder_counts({files, links}, folder_uuid) do
    {Map.get(files, folder_uuid, 0), Map.get(links, folder_uuid, 0)}
  end

  # Fills `counts: nil` placeholders left by `build_move_action/1` with a
  # single batched lookup across every action's folder — the whole plan's
  # folder counts come from one pair of grouped queries (X1), not one pair
  # per action.
  defp finalize_counts(actions) do
    counts =
      actions
      |> Enum.map(fn
        %{folder: %Folder{uuid: uuid}} -> uuid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
  end

  # R9/R10: only the columns a plan needs (never the full row, which would
  # pull every translatable/jsonb field this schema carries), ordered by
  # `inserted_at`/`uuid` — a deterministic, readable report order.
  defp light_people do
    Person
    |> where([p], p.status != "trashed")
    |> order_by([p], asc: p.inserted_at, asc: p.uuid)
    |> select([p], struct(p, [:uuid, :name, :status, :inserted_at]))
    |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
