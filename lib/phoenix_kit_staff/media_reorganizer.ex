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

  Contract (design §9/§10 of `2026-09-15-media-reorganizer-design.md`):

    * **No configured `:attachments_parent_folder` hook → `:report`-only.**
      Orphan reports are still produced (informational, no writes); no
      `:move`, no `:trash`, no pointer back-fill (staff writes no pointer
      at all — see below).
    * **A hook that raises, exits, or returns anything but `{:ok, uuid}` or
      an explicit `nil`** is a hook FAILURE: the record is skipped (no
      move planned for it) and counted into one `kind: :hook_error` report
      for the whole plan. Only an explicit `nil` means "root".
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
    * **A legacy folder live somewhere other than root or the resolved
      parent** (the owner moved it, or it predates a parent-hook change)
      is left alone and reported `kind: :relocated` — never adopted or
      moved. Staff's parent hook receives the acting user, so the report
      says the answer may depend on which user resolves it (E6).
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

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitStaff.Attachments
  alias PhoenixKitStaff.Schemas.Person

  @legacy_prefix "staff-person-"

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds staff's reorganizer plan: one `:move` action per live person whose
  current folder does not already sit at the hook-resolved parent under its
  deterministic name, a `:report` (`kind: :duplicate`) per person whose
  legacy folder is live in both places at once, a `:report`
  (`kind: :relocated`) per person whose legacy folder is live somewhere
  other than root or the resolved parent, a `:report` (`kind: :hook_error`)
  counting every candidate the configured hook failed for, and a `:report`
  (`kind: :orphan`) per legacy folder whose record is missing or trashed.

  `opts` is accepted for parity with the `Source.plan/2` contract; staff has
  no pending-folder rules to tune, so nothing in it is read.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    {resource_actions, resolved_parents} = resource_plan(actor_uuid)

    resource_actions ++ orphan_actions(resolved_parents)
  end

  # ── People ───────────────────────────────────────────────────────

  defp resource_plan(actor_uuid) do
    if hook_configured?() do
      build_resource_plan(live_people(), actor_uuid)
    else
      {[], []}
    end
  end

  defp hook_configured? do
    case Application.get_env(:phoenix_kit_staff, :attachments_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        Code.ensure_loaded?(mod) and
          (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2))

      _ ->
        false
    end
  end

  # Candidate detection needs no hook call: a live folder anywhere named
  # after the person's legacy name. Only candidates go on to have the
  # host's parent hook resolved — a person with nothing pointing at them
  # never triggers a (possibly writing) host hook, and there is no other,
  # subject-less call to resolve a parent for orphans in the absence of any
  # candidate (R8) — a host with zero candidate people is left untouched
  # beyond root-level orphan detection.
  defp build_resource_plan(people, actor_uuid) do
    {mod, fun} = Application.get_env(:phoenix_kit_staff, :attachments_parent_folder)

    prelim =
      Enum.map(people, fn person ->
        %{record: person, name: Attachments.root_folder_name(person.uuid)}
      end)

    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.name))

    candidates = Enum.filter(prelim, &Map.has_key?(by_name, &1.name))

    {resolved_candidates, hook_error_count} = resolve_candidates(candidates, mod, fun, actor_uuid)

    entries = Enum.map(resolved_candidates, &resolve_entry(&1, by_name))

    {relocated, resolved} = Enum.split_with(entries, & &1.relocated)
    relocated_actions = Enum.map(relocated, &build_relocated_action/1)

    resolved_parents =
      resolved |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {ambiguous, normal} = Enum.split_with(resolved, & &1.ambiguous)
    {with_folder, _without_folder} = Enum.split_with(normal, & &1.folder)

    move_actions = with_folder |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    dup_actions = Enum.map(ambiguous, &build_duplicate_action/1)
    hook_error_actions = hook_error_action(hook_error_count)

    all_actions = move_actions ++ dup_actions ++ relocated_actions ++ hook_error_actions

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

  defp resolve_parent(mod, fun, actor_uuid, person_uuid) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
        guarded_hook_call(fn -> apply(mod, fun, [:person, actor_uuid, person_uuid]) end)

      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
        guarded_hook_call(fn -> apply(mod, fun, [:person, actor_uuid]) end)

      true ->
        :error
    end
  end

  defp guarded_hook_call(fun) do
    case fun.() do
      {:ok, uuid} when is_binary(uuid) -> {:ok, uuid}
      {:ok, nil} -> {:ok, nil}
      nil -> {:ok, nil}
      _other -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # Resolves one person's current folder: the legacy name looked up under
  # the resolved parent first, then at root (module's own order — X9: only
  # these two places, never "anywhere else" the folder might have been
  # moved to). A live match at both is ambiguous (X11). A candidate always
  # has at least one live match somewhere (that's what made it a
  # candidate in the first place) — when neither the resolved parent nor
  # root has one, the folder is live elsewhere and reported `:relocated`,
  # never adopted.
  defp resolve_entry(d, by_name) do
    matches = Map.get(by_name, d.name, [])
    under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
    at_root = Enum.find(matches, &is_nil(&1.parent_uuid))

    case {under_parent, at_root} do
      {nil, nil} ->
        Map.merge(d, %{folder: nil, ambiguous: nil, relocated: List.first(matches)})

      {f, nil} ->
        Map.merge(d, %{folder: f, ambiguous: nil, relocated: nil})

      {nil, f} ->
        Map.merge(d, %{folder: f, ambiguous: nil, relocated: nil})

      {f1, f2} ->
        Map.merge(d, %{folder: nil, ambiguous: {f1, f2}, relocated: nil})
    end
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` is a
  # no-op — filtered here since this Source has no core `Action.noop?/1`
  # to lean on. `on_conflict: :report` (D3, X8): staff writes no pointer,
  # so a folder the engine renamed on a name conflict would be
  # permanently orphaned — nothing could resolve it by name again.
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

  defp build_duplicate_action(%{record: person, ambiguous: {f1, f2}}) do
    %{
      source: "staff",
      kind: :duplicate,
      label: label_for(person),
      op: :report,
      counts: nil,
      reason:
        "legacy folder found live in two places (#{f1.uuid} and #{f2.uuid}) — pick one and remove the other"
    }
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

  defp label_for(%{name: name, uuid: uuid}) do
    if is_binary(name) and name != "", do: name, else: uuid
  end

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
  # live person (missing, or trashed — same status rule `live_people/0`
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
  # parent whose name starts with the legacy prefix.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
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
  # reported, and the missing case is distinguished by a plain miss.
  defp load_candidate_people(candidates) do
    uuids = candidates |> Enum.map(fn {_folder, uuid} -> uuid end) |> Enum.uniq()

    Person
    |> where([p], p.uuid in ^uuids)
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
          File
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

  defp live_people do
    Person |> where([p], p.status != "trashed") |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
