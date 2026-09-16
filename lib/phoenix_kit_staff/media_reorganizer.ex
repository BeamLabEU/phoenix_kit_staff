defmodule PhoenixKitStaff.MediaReorganizer do
  @moduledoc """
  Staff's media-reorganizer plan source.

  Implements the contract of core's `PhoenixKit.Modules.Storage.Reorganizer.Source`
  (shipped in core 2.24) without declaring `@behaviour`: the `:phoenix_kit`
  pin stays `~> 2.0`, which still admits cores that predate the engine, and
  an undefined behaviour would warn in those hosts. `plan/2` returns plain
  maps, so nothing here depends on the engine at compile time; see
  `PhoenixKitStaff.media_reorganizer/0` for the registration comment.

  Contract (design §9/§10/§11 of `2026-09-15-media-reorganizer-design.md`):

    * **No configured `:attachments_parent_folder` hook → `:report`-only.**
      Orphan reports are still produced (informational, no writes); no
      `:move`, no `:trash`, no pointer back-fill (staff writes no pointer
      at all — see below). A configured value that isn't a `{mod, fun}`
      tuple with an exported function — a typo, a removed function, or
      plain garbage that isn't even a tuple — is a distinct failure
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
  adopted current folder, a `:report` (`kind: :hook_error`) naming every
  candidate the configured hook failed (or wasn't callable) for, a
  `:report` (`kind: :hook_nil`) naming every candidate whose parented
  folder was left in place because the hook answered root (both cap the
  named list at 10, then just count the rest), and a `:report`
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

        {:not_callable, config} ->
          {[not_callable_hook_action(config)], []}

        :none ->
          {[], []}
      end

    resource_actions ++ orphan_actions(resolved_parents)
  end

  # ── People ───────────────────────────────────────────────────────

  # T3/U7/V3: a configured value that isn't a `{mod, fun}` tuple with an
  # exported function — a typo, a removed function, or plain garbage (not
  # even a tuple) — is one `:hook_error` "not callable" failure, distinct
  # from "no hook configured at all" (`nil`, unconfigured). It must never
  # silently degrade to report-only (E1) without saying why nothing moved.
  defp hook_status do
    case Application.get_env(:phoenix_kit_staff, :attachments_parent_folder) do
      nil ->
        :none

      {mod, fun} = config when is_atom(mod) and is_atom(fun) ->
        if callable?(mod, fun), do: {:ok, mod, fun}, else: {:not_callable, config}

      garbage ->
        {:not_callable, garbage}
    end
  end

  defp callable?(mod, fun) do
    Code.ensure_loaded?(mod) and
      (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2))
  end

  defp not_callable_hook_action(config) do
    %{
      source: "staff",
      kind: :hook_error,
      op: :report,
      label: "attachments parent hook",
      counts: nil,
      reason: "configured parent hook #{inspect(config)} is not callable / invalid config"
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

    {resolved_candidates, hook_error_records} =
      resolve_candidates(candidates, mod, fun, actor_uuid)

    # NEW-10/U4: orphan scope is every parent a SUCCESSFUL hook answer named
    # for ANY candidate, regardless of that candidate's outcome — taken here,
    # before `apply_nil_root_guard/1` below can overwrite an entry's
    # `parent_uuid` with the parent a folder merely happens to live under
    # (F1 adoption). That adopted parent was never returned by the hook, so
    # it must never enter orphan scope either.
    resolved_parents =
      resolved_candidates |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    entries =
      resolved_candidates
      |> Enum.map(&resolve_entry(&1, by_name))
      |> Enum.map(&apply_nil_root_guard/1)

    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, without_folder} = Enum.split_with(normal, & &1.folder)

    move_actions = with_folder |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    dup_actions = Enum.map(ambiguous, &build_duplicate_action/1)
    hook_error_actions = hook_error_action(hook_error_records)
    hook_nil_actions = hook_nil_action(Enum.filter(entries, & &1.hook_nil))

    claimed = claimed_folder_uuids(with_folder, ambiguous)

    # F5/T5: every live legacy-named copy other than a record's adopted
    # current folder gets its own `:relocated` report — all of them, not
    # just the first — except a copy that is itself another record's
    # claimed (adopted) folder, which is never also reported `:relocated`.
    # U9: includes `ambiguous` too — a THIRD live copy beyond the two the
    # duplicate report already names must still surface here, not be
    # dropped.
    stray_actions = stray_relocated_actions(with_folder ++ without_folder ++ ambiguous, claimed)

    all_actions =
      move_actions ++ dup_actions ++ stray_actions ++ hook_error_actions ++ hook_nil_actions

    {finalize_counts(all_actions), resolved_parents}
  end

  # R2: resolves the desired parent for every candidate via the host's
  # exact hook, distinguishing an explicit `nil` (root) from a hook that
  # raised/exited/returned anything else (failure — the candidate is
  # dropped from `entries` and its record kept in `hook_error_records`
  # (U8 — the report names who was skipped), never treated as "root").
  defp resolve_candidates(candidates, mod, fun, actor_uuid) do
    {entries, errors} =
      Enum.reduce(candidates, {[], []}, fn c, {acc, errs} ->
        case resolve_parent(mod, fun, actor_uuid, c.record.uuid) do
          {:ok, parent_uuid} -> {[Map.put(c, :parent_uuid, parent_uuid) | acc], errs}
          :error -> {acc, [c.record | errs]}
        end
      end)

    {Enum.reverse(entries), Enum.reverse(errors)}
  end

  # T3: `build_resource_plan/4` is only reached once `hook_status/0` has
  # already confirmed one of the two arities is exported on a loaded
  # module — there is no third "not callable" outcome left to handle here.
  defp resolve_parent(mod, fun, actor_uuid, person_uuid) do
    if function_exported?(mod, fun, 3) do
      guarded_hook_call(mod, fun, fn -> apply(mod, fun, [:person, actor_uuid, person_uuid]) end)
    else
      guarded_hook_call(mod, fun, fn -> apply(mod, fun, [:person, actor_uuid]) end)
    end
  end

  # T1: every answer is cast through `Ecto.UUID.cast/1` and downcased —
  # `{:ok, ""}` / `{:ok, "not-a-uuid"}` are hook FAILURES (`:error`), never
  # sent into a later `in ^uuids` query (which would raise a CastError and
  # take down the whole plan). F2: an explicit `{:ok, nil}` or bare `nil`
  # means root. U6: every failure is logged with `{mod, fun}` and the kind
  # (`:person`) it came from — an exception, AND a bad return value alike
  # (a silently-counted `{:error, _}` or `{:ok, "x"}` tells the owner
  # nothing about which hook misbehaved).
  defp guarded_hook_call(mod, fun_name, fun) do
    case fun.() do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, uuid} ->
        case valid_uuid(uuid) do
          nil ->
            log_bad_hook_return(mod, fun_name, {:ok, uuid})
            :error

          cast ->
            {:ok, cast}
        end

      nil ->
        {:ok, nil}

      other ->
        log_bad_hook_return(mod, fun_name, other)
        :error
    end
  rescue
    error ->
      Logger.warning(
        "Attachments parent hook #{inspect(mod)}.#{fun_name} (person) raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    error_kind, reason ->
      Logger.warning(
        "Attachments parent hook #{inspect(mod)}.#{fun_name} (person) #{error_kind}: " <>
          inspect(reason)
      )

      :error
  end

  defp log_bad_hook_return(mod, fun_name, value) do
    Logger.warning(
      "Attachments parent hook #{inspect(mod)}.#{fun_name} (person) returned #{inspect(value)}"
    )
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

  # U9: the ambiguous pair claims two folders, but any FURTHER live match
  # (neither root nor the resolved parent) is a stray copy of its own —
  # still reported `:relocated` (via `stray_relocated_actions/2` below),
  # never silently dropped just because the duplicate report already named
  # the other two.
  defp resolve_entry_result(d, matches, under_parent, at_root)
       when not is_nil(under_parent) and not is_nil(at_root) do
    stray = Enum.reject(matches, &(&1.uuid in [under_parent.uuid, at_root.uuid]))
    Map.merge(d, %{folder: nil, ambiguous: [under_parent, at_root], stray_legacy: stray})
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

  # F5/T5 + U3: batched over the whole plan so naming a stray copy's actual
  # (third-party) parent for the report never costs a query per copy.
  defp stray_relocated_actions(entries, claimed) do
    pairs =
      Enum.flat_map(entries, fn entry ->
        entry.stray_legacy
        |> Enum.reject(&MapSet.member?(claimed, &1.uuid))
        |> Enum.map(&{entry, &1})
      end)

    parent_names = load_stray_parent_names(pairs)

    Enum.map(pairs, fn {entry, folder} ->
      build_relocated_action(%{
        record: entry.record,
        relocated: folder,
        target_parent_uuid: entry.parent_uuid,
        parent_names: parent_names
      })
    end)
  end

  # Only a stray parent that is neither root nor the record's own target
  # needs a name — those two cases already have their own wording.
  defp load_stray_parent_names(pairs) do
    uuids =
      pairs
      |> Enum.map(fn {entry, folder} -> other_parent_uuid(folder, entry.parent_uuid) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case uuids do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids)
        |> select([f], {f.uuid, f.name})
        |> repo().all()
        |> Map.new()
    end
  end

  defp other_parent_uuid(%Folder{parent_uuid: nil}, _target_parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, _target_parent_uuid), do: parent_uuid

  # A legacy folder that is live but neither at root nor under the
  # resolved parent — the owner moved it elsewhere, or it predates a
  # parent-hook change. Left alone, never adopted or moved. E6: staff's
  # hook receives the acting user, so the report names that dependency
  # instead of implying the folder is unconditionally misplaced.
  defp build_relocated_action(%{record: person, relocated: folder} = ctx) do
    %{
      source: "staff",
      kind: :relocated,
      op: :report,
      label: label_for(person),
      folder: folder,
      counts: nil,
      reason:
        relocated_reason(
          folder,
          Map.get(ctx, :target_parent_uuid),
          Map.get(ctx, :parent_names, %{})
        )
    }
  end

  # U3: the reason names the copy's actual place — at the media root,
  # already live as a twin under the very parent the record is headed to,
  # or by name under a genuine third-party parent — instead of a blanket
  # "under a different parent" that reads wrong for all three cases. Only
  # the third branch is reachable for staff today: `resolve_entry/2` above
  # always special-cases root and the resolved parent as the two possible
  # "chosen" spots (a live match at either becomes the adopted folder, or
  # — if both are live at once — the whole record is `:duplicate` instead
  # of one adopted + a stray), so a genuine stray never lands at root or
  # at the target parent. Kept for parity with the other reorganizer
  # modules and in case that changes.
  defp relocated_reason(%Folder{parent_uuid: nil} = folder, _target_parent_uuid, _names) do
    "legacy folder #{folder.uuid} is live at the media root — left alone, never adopted; " <>
      acting_user_note()
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid} = folder, parent_uuid, _names) do
    "legacy folder #{folder.uuid} is already live as a twin under the target parent — left " <>
      "alone; an eventual move there will collide, landing as \"name (N)\"; " <>
      acting_user_note()
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid} = folder, _target_parent_uuid, names) do
    parent_label = Map.get(names, parent_uuid, parent_uuid)

    "legacy folder #{folder.uuid} is live under #{parent_label} — left alone, never adopted; " <>
      acting_user_note()
  end

  defp acting_user_note do
    "whether it belongs there may depend on the acting user (the parent hook receives the " <>
      "actor and can resolve differently for someone else)"
  end

  defp hook_error_action([]), do: []

  defp hook_error_action(records) do
    [
      %{
        source: "staff",
        kind: :hook_error,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(records)} record(s) skipped: the configured parent hook raised, exited, " <>
            "or returned neither {:ok, uuid} nor nil (#{labels_summary(records)})"
      }
    ]
  end

  # F1/U8: one report for the whole plan, naming the records it applied to
  # (up to 10, then a count of the rest) — not a bare counter.
  defp hook_nil_action([]), do: []

  defp hook_nil_action(entries) do
    records = Enum.map(entries, & &1.record)

    [
      %{
        source: "staff",
        kind: :hook_nil,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(records)} record(s): the parent hook answered root for a folder living " <>
            "under a parent — left in place (#{labels_summary(records)})"
      }
    ]
  end

  # U8: `:hook_error`/`:hook_nil` reports name up to 10 records so the owner
  # knows where to look, then just a count of the rest — never a bare total.
  defp labels_summary(records) do
    {shown, rest} = records |> Enum.map(&label_for/1) |> Enum.split(10)

    case rest do
      [] -> Enum.join(shown, ", ")
      more -> Enum.join(shown, ", ") <> ", … and #{length(more)} more"
    end
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
