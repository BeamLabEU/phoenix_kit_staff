defmodule PhoenixKitStaff.Attachments do
  @moduledoc """
  Folder-scoped media attachments for a staff person, backed by core
  `PhoenixKit.Modules.Storage` (the same per-resource-folder convention
  `phoenix_kit_catalogue`/`phoenix_kit_locations` use — no module-owned
  table, no migration).

  Each person owns a deterministic root folder `staff-person-<uuid>` for
  generic files, with a nested **`Images`** subfolder (`parent_uuid` = the
  root) for images — i.e. all of a person's files in one folder, images in a
  folder inside it. Folders are resolved **by name** on every read (never
  cached on `Person`, so an admin renaming/deleting the folder in
  `/admin/media` can't strand a dangling uuid) and created lazily on first
  upload. The `[:name, :parent_uuid]` unique index in core makes
  find-or-create race-safe.

  Files live in core `phoenix_kit_files` under the folder; uploading/browsing
  is done by `MediaSelectorModal` (scoped to the folder), so this module only
  resolves folders, lists their files, (un)links picked files, and removes
  them — mirroring `PhoenixKitCatalogue.Attachments`' write semantics
  (soft-trash a sole-owner file, unlink a shared one). It never hard-deletes
  a possibly-shared asset.
  """

  require Logger

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitStaff.Schemas.Person

  @images_folder_name "Images"
  @avatar_key "avatar_uuid"
  # Inline grid is unpaginated; cap the query so a pathological folder can't
  # freeze the tab. The picker uploads ≤20/submit, so this is generous.
  @list_limit 200

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Deterministic root folder name for a person's files."
  @spec root_folder_name(binary()) :: binary()
  def root_folder_name(person_uuid), do: "staff-person-#{person_uuid}"

  # ── Folder resolution ──────────────────────────────────────────────

  @doc """
  Resolves the folder uuid for `kind` (`:files` → root, `:images` → the
  nested `Images` subfolder) **without creating** it. Returns the uuid or
  `nil` (used on render so viewing a tab doesn't spawn empty folders).
  """
  @spec folder_uuid(binary(), :files | :images) :: binary() | nil
  def folder_uuid(person_uuid, :files),
    do: uuid_of(get_folder(root_folder_name(person_uuid), nil))

  def folder_uuid(person_uuid, :images) do
    case get_folder(root_folder_name(person_uuid), nil) do
      %Folder{uuid: root} -> uuid_of(get_folder(@images_folder_name, root))
      _ -> nil
    end
  end

  @doc """
  Find-or-create the folder for `kind`, returning `{:ok, uuid}` or
  `{:error, reason}`. Race-safe: a lost create (unique `[:name, :parent_uuid]`)
  re-resolves the winner. Call when an action needs the folder to exist
  (opening the picker / handling a selection).
  """
  @spec ensure_folder(binary(), :files | :images, binary() | nil) ::
          {:ok, binary()} | {:error, term()}
  def ensure_folder(person_uuid, :files, actor_uuid) do
    find_or_create(root_folder_name(person_uuid), nil, actor_uuid)
  end

  def ensure_folder(person_uuid, :images, actor_uuid) do
    with {:ok, root} <- find_or_create(root_folder_name(person_uuid), nil, actor_uuid) do
      find_or_create(@images_folder_name, root, actor_uuid)
    end
  end

  defp find_or_create(name, parent_uuid, user_uuid) do
    case get_folder(name, parent_uuid) do
      %Folder{uuid: uuid} ->
        {:ok, uuid}

      nil ->
        case Storage.create_folder(%{name: name, parent_uuid: parent_uuid, user_uuid: user_uuid}) do
          {:ok, %Folder{uuid: uuid}} ->
            {:ok, uuid}

          # Lost the create race against a concurrent first-upload — the
          # unique [:name, :parent_uuid] constraint rejected us; re-resolve.
          {:error, %Ecto.Changeset{}} ->
            case get_folder(name, parent_uuid) do
              %Folder{uuid: uuid} -> {:ok, uuid}
              _ -> {:error, :folder_unavailable}
            end
        end
    end
  rescue
    error ->
      Logger.warning("[Staff] ensure_folder #{name} failed: #{inspect(error)}")
      {:error, :folder_unavailable}
  end

  defp get_folder(name, nil) do
    from(f in Folder, where: f.name == ^name and is_nil(f.parent_uuid), limit: 1) |> repo().one()
  rescue
    error ->
      Logger.warning("[Staff] get_folder #{name} failed: #{inspect(error)}")
      nil
  end

  defp get_folder(name, parent_uuid) do
    from(f in Folder, where: f.name == ^name and f.parent_uuid == ^parent_uuid, limit: 1)
    |> repo().one()
  rescue
    error ->
      Logger.warning("[Staff] get_folder #{name} failed: #{inspect(error)}")
      nil
  end

  defp uuid_of(%Folder{uuid: uuid}), do: uuid
  defp uuid_of(_), do: nil

  # ── Listing ────────────────────────────────────────────────────────

  @doc """
  Files attached to `folder_uuid` (home-folder files plus those linked in via
  `FolderLink`), newest first, excluding trashed. `:only` narrows by type:
  `:images` (file_type == "image"), `:non_images` (everything else), or `:all`
  (default). Defensive — keeps a tab showing only its own kind even if a stray
  file of the other kind landed in the folder.
  """
  @spec list_files(binary() | nil, keyword()) :: [File.t()]
  def list_files(nil, _opts), do: []

  def list_files(folder_uuid, opts) do
    linked = from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid, select: fl.file_uuid)

    base =
      from(f in File,
        where:
          (f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked)) and f.status != "trashed",
        order_by: [desc: f.inserted_at],
        limit: @list_limit
      )

    query =
      case Keyword.get(opts, :only, :all) do
        :images -> where(base, [f], f.file_type == "image")
        :non_images -> where(base, [f], f.file_type != "image")
        _ -> base
      end

    repo().all(query)
  rescue
    error ->
      Logger.warning("[Staff] list_files #{folder_uuid} failed: #{inspect(error)}")
      []
  end

  @doc "Whether the file with this uuid is an image (by Storage `file_type`)."
  @spec image?(binary()) :: boolean()
  def image?(file_uuid) do
    match?(%File{file_type: "image"}, Storage.get_file(file_uuid))
  rescue
    _ -> false
  end

  # ── Attach / detach ────────────────────────────────────────────────

  @doc """
  Ensures `file_uuid` is attached to `folder_uuid`: a no-op if already home
  there (the modal's scoped uploads land here directly); adopts an orphan file
  as home; otherwise adds a `FolderLink` so a file picked from elsewhere
  appears here without being moved from its owner.
  """
  @spec attach(binary(), binary()) :: :ok
  def attach(file_uuid, folder_uuid) do
    case Storage.get_file(file_uuid) do
      nil ->
        :ok

      %File{folder_uuid: ^folder_uuid} ->
        :ok

      %File{folder_uuid: nil} = file ->
        file |> Ecto.Changeset.change(%{folder_uuid: folder_uuid}) |> repo().update()
        :ok

      %File{} ->
        %FolderLink{}
        |> FolderLink.changeset(%{folder_uuid: folder_uuid, file_uuid: file_uuid})
        |> repo().insert(on_conflict: :nothing, conflict_target: [:folder_uuid, :file_uuid])

        :ok
    end
  rescue
    error ->
      Logger.warning("[Staff] attach #{file_uuid} failed: #{inspect(error)}")
      :ok
  end

  @doc """
  Removes a file from `folder_uuid`. If the file's home is this folder and it
  is not linked elsewhere → soft-trash it (recoverable in the media trash). If
  it is also linked elsewhere → promote a link to home (keeps it alive). If it
  is here only via a `FolderLink` → just drop the link. Mirrors core's
  non-destructive convention; never hard-deletes a shared asset.
  """
  @spec detach(binary(), binary() | nil) :: :ok | {:error, term()}
  def detach(_file_uuid, nil), do: :ok

  def detach(file_uuid, folder_uuid) do
    case Storage.get_file(file_uuid) do
      nil -> :ok
      %File{folder_uuid: ^folder_uuid} = file -> detach_home(file)
      %File{} -> detach_link(file_uuid, folder_uuid)
    end
  rescue
    error ->
      Logger.warning("[Staff] detach #{file_uuid} failed: #{inspect(error)}")
      {:error, error}
  end

  defp detach_home(file) do
    case list_links(file.uuid) do
      [] ->
        case soft_trash(file) do
          {:ok, _} -> :ok
          err -> err
        end

      [%FolderLink{} = link | _] ->
        repo().transaction(fn ->
          file |> Ecto.Changeset.change(%{folder_uuid: link.folder_uuid}) |> repo().update!()
          repo().delete!(link)
        end)
        |> case do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  defp detach_link(file_uuid, folder_uuid) do
    from(fl in FolderLink, where: fl.file_uuid == ^file_uuid and fl.folder_uuid == ^folder_uuid)
    |> repo().delete_all()

    :ok
  end

  defp soft_trash(%File{} = file) do
    file
    |> Ecto.Changeset.change(%{
      status: "trashed",
      trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> repo().update()
  end

  defp list_links(file_uuid) do
    from(fl in FolderLink, where: fl.file_uuid == ^file_uuid) |> repo().all()
  end

  # ── Lifecycle ──────────────────────────────────────────────────────

  @doc """
  Permanently purges a person's media — deletes the root folder and its whole
  subtree (the nested `Images` folder + every file, including bucket copies)
  via core's cascading `delete_folder_completely/1`. Best-effort: logs and
  returns `:ok` on any failure so it never blocks a person deletion. Call
  only on a **permanent** delete (soft-trash keeps the files).
  """
  @spec purge_person_media(binary()) :: :ok
  def purge_person_media(person_uuid) do
    case get_folder(root_folder_name(person_uuid), nil) do
      %Folder{} = folder ->
        Storage.delete_folder_completely(folder)
        :ok

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("[Staff] purge_person_media #{person_uuid} failed: #{inspect(error)}")
      :ok
  end

  # ── Template helpers ───────────────────────────────────────────────

  @doc "Heroicon name for a file based on its Storage type / mime."
  @spec file_icon(map()) :: String.t()
  def file_icon(%{file_type: "image"}), do: "hero-photo"
  def file_icon(%{file_type: "video"}), do: "hero-film"
  def file_icon(%{file_type: "audio"}), do: "hero-musical-note"
  def file_icon(%{file_type: "archive"}), do: "hero-archive-box"
  def file_icon(%{mime_type: "application/pdf"}), do: "hero-document-text"
  def file_icon(_), do: "hero-document"

  @doc "Human-readable byte count. Nil-safe."
  @spec format_file_size(integer() | nil) :: String.t()
  def format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_file_size(_), do: "—"

  @doc "Public download URL for a file (nil-safe)."
  @spec download_url(map()) :: String.t() | nil
  def download_url(%File{} = file), do: safe_url(fn -> Storage.get_public_url(file) end)
  def download_url(_), do: nil

  @doc "Thumbnail URL for an image file, falling back to the original (nil-safe)."
  @spec thumb_url(map()) :: String.t() | nil
  def thumb_url(%File{} = file),
    do: safe_url(fn -> Storage.get_public_url_by_variant(file, "thumbnail") end)

  def thumb_url(_), do: nil

  defp safe_url(fun) do
    fun.()
  rescue
    _ -> nil
  end

  # ── Avatar ─────────────────────────────────────────────────────────
  #
  # A person's avatar is a single image-file pointer kept in `Person.metadata`
  # (`"avatar_uuid"`) — no new column, mirroring catalogue's featured-image
  # pointer. The image is one of the person's Images-folder files (the avatar
  # picker is scoped to that folder), so uploads/picks stay in sync with the
  # Images tab. Server-owned: written only via `set_avatar/2` / `clear_avatar/1`.

  @doc "The person's avatar file uuid (from metadata), or nil."
  @spec avatar_uuid(Person.t()) :: binary() | nil
  def avatar_uuid(%Person{metadata: m}) when is_map(m) do
    case Map.get(m, @avatar_key) do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  def avatar_uuid(_), do: nil

  @doc "The person's avatar `File` struct, or nil if unset / missing / trashed."
  @spec avatar_file(Person.t()) :: File.t() | nil
  def avatar_file(person) do
    case avatar_uuid(person) do
      nil ->
        nil

      uuid ->
        case Storage.get_file(uuid) do
          %File{status: "trashed"} -> nil
          %File{} = file -> file
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  @doc "Thumbnail URL for the person's avatar (or nil)."
  @spec avatar_url(Person.t()) :: String.t() | nil
  def avatar_url(person), do: person |> avatar_file() |> thumb_url()

  @doc "Points the person's avatar at `file_uuid` (server-owned metadata write)."
  @spec set_avatar(Person.t(), binary()) :: {:ok, Person.t()} | {:error, term()}
  def set_avatar(%Person{} = person, file_uuid) when is_binary(file_uuid) and file_uuid != "",
    do: put_metadata(person, @avatar_key, file_uuid)

  @doc "Clears the person's avatar pointer."
  @spec clear_avatar(Person.t()) :: {:ok, Person.t()} | {:error, term()}
  def clear_avatar(%Person{} = person), do: put_metadata(person, @avatar_key, nil)

  defp put_metadata(person, key, value) do
    metadata = person.metadata || %{}

    metadata =
      if is_nil(value), do: Map.delete(metadata, key), else: Map.put(metadata, key, value)

    person |> Ecto.Changeset.change(metadata: metadata) |> repo().update()
  end
end
