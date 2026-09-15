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

  `plan/2` derives the desired parent from the exact hook
  (`Attachments.parent_folder_uuid/3`) a fresh upload uses. Staff has no
  folder-name hook — a person's folder name is always the deterministic
  `staff-person-<uuid>` (`Attachments.root_folder_name/1`) — and no cached
  folder pointer, so a plan never needs an `after_move` back-fill: the
  folder is always resolved by name, the same way every read does.

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

  @doc """
  Builds staff's reorganizer plan: one `:move` action per live person whose
  current folder does not already sit at the hook-resolved parent under its
  deterministic name, plus a `:report` (`kind: :orphan`) per legacy folder
  whose record is missing or trashed.

  `opts` is accepted for parity with the `Source.plan/2` contract; staff has
  no pending-folder rules to tune, so nothing in it is read.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, _opts \\ []) do
    desired = resolve_desired(live_people(), actor_uuid)

    resource_actions(desired) ++ orphan_actions(desired)
  end

  # ── People ───────────────────────────────────────────────────────

  defp resolve_desired(people, actor_uuid) do
    Enum.map(people, fn person ->
      %{
        record: person,
        parent_uuid: Attachments.parent_folder_uuid(:person, actor_uuid, person.uuid),
        name: Attachments.root_folder_name(person.uuid)
      }
    end)
  end

  # Every folder lookup for the whole batch runs as two preloaded queries
  # (legacy names at root, legacy names under a resolved parent) instead of
  # up to two round trips per record.
  defp resource_actions(desired) do
    by_root_name = preload_by_root_name(Enum.map(desired, & &1.name))
    by_parent_name = preload_by_parent_name(desired)

    desired
    |> Enum.map(&resource_action(&1, by_root_name, by_parent_name))
    |> Enum.reject(&is_nil/1)
  end

  defp resource_action(desired, by_root_name, by_parent_name) do
    %{record: person, parent_uuid: parent_uuid, name: name} = desired

    case current_folder(desired, by_root_name, by_parent_name) do
      nil ->
        nil

      %Folder{} = folder ->
        if noop_move?(folder, parent_uuid, name) do
          nil
        else
          %{
            source: "staff",
            kind: :person,
            label: person.name || person.uuid,
            op: :move,
            folder: folder,
            parent_uuid: parent_uuid,
            name: name,
            counts: counts(folder.uuid),
            on_conflict: :suffix,
            after_move: nil
          }
        end
    end
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or an
  # accepted `"name (N)"` suffix variant) is a no-op — filtered here since
  # this Source has no core `Action.noop?/1` to lean on. Staff has no
  # pointer to back-fill, so unlike catalogue's `noop_move?/3` there is no
  # `after_move` case to preserve: an in-place folder is always a no-op.
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  # One query for every distinct legacy name in the batch, at root.
  defp preload_by_root_name(names) do
    case Enum.reject(Enum.uniq(names), &is_nil/1) do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.parent_uuid))
        |> repo().all()
        |> Map.new(&{&1.name, &1})
    end
  end

  # One query for every distinct legacy name under every distinct resolved
  # parent in the batch — still one round trip for the whole batch.
  defp preload_by_parent_name(desired) do
    names = desired |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    parents = desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if names == [] or parents == [] do
      %{}
    else
      Folder
      |> where([f], f.name in ^names and f.parent_uuid in ^parents)
      |> repo().all()
      |> Map.new(&{{&1.name, &1.parent_uuid}, &1})
    end
  end

  # Legacy deterministic name at root, else under the resolved parent. `nil`
  # when neither exists (nothing to move — the module creates one on first
  # upload) or the only match is trashed (skipped, not a valid current
  # folder).
  defp current_folder(desired, by_root_name, by_parent_name) do
    %{name: name, parent_uuid: parent_uuid} = desired

    live_or_nil(Map.get(by_root_name, name)) ||
      (parent_uuid && live_or_nil(Map.get(by_parent_name, {name, parent_uuid})))
  end

  defp live_or_nil(%Folder{trashed_at: nil} = folder), do: folder
  defp live_or_nil(_), do: nil

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`staff-person-<uuid>`) at the media root or under
  # a parent this batch's hook resolved to, whose uuid no longer names a
  # live person (missing, or trashed — same status rule `live_people/0`
  # above uses to drop it from the plan) is reported so a host can collect
  # it. Never `:move`d or `:trash`ed here — staff owns no "orphans"
  # container; a legacy folder that IS a live person's current folder is
  # left to `resource_action/3` above. Reuses `desired`'s `parent_uuid`s
  # (already resolved once per person in `plan/2`) rather than calling the
  # hook again — it can be a DB lookup or create a folder on the host side.
  defp orphan_actions(desired) do
    resolved_parents =
      desired
      |> Enum.map(& &1.parent_uuid)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        people_by_uuid = load_candidate_people(candidates)

        candidates
        |> Enum.map(&orphan_action(&1, people_by_uuid))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One query for every legacy-named folder at root or under a resolved
  # parent — not a query per folder.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> repo().all()
    |> Enum.map(&{&1, legacy_uuid(&1.name)})
    |> Enum.filter(fn {_folder, uuid} -> uuid end)
  end

  defp legacy_uuid(name) do
    with true <- String.starts_with?(name, @legacy_prefix),
         uuid <- String.replace_prefix(name, @legacy_prefix, ""),
         {:ok, _} <- Ecto.UUID.cast(uuid) do
      uuid
    else
      _ -> nil
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

  defp orphan_action({folder, uuid}, people_by_uuid) do
    case Map.get(people_by_uuid, uuid) do
      %{status: status} when status != "trashed" ->
        nil

      person ->
        counts = counts(folder.uuid)

        %{
          source: "staff",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: counts,
          reason: orphan_reason(person, counts)
        }
    end
  end

  defp orphan_reason(nil, {files, _links}), do: "record missing, #{files} file(s)"

  defp orphan_reason(%{status: status}, {files, _links}),
    do: "record status #{status}, #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # Counts ALL rows regardless of status (including trashed files) — the
  # core engine re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time count
  # that excluded trashed files would fail every folder holding one.
  defp counts(folder_uuid) do
    files =
      File
      |> where([f], f.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    links =
      FolderLink
      |> where([l], l.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    {files, links}
  end

  defp live_people do
    Person |> where([p], p.status != "trashed") |> repo().all()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
