defmodule PhoenixKitStaff.Departments do
  @moduledoc "CRUD for departments."

  import Ecto.Query

  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Department

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Lists departments. Accepts `:preload`."
  @spec list(keyword()) :: [Department.t()]
  def list(opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    Department
    |> order_by([d], asc: d.name)
    |> preload(^preload)
    |> repo().all()
  end

  @doc "Fetches a department by uuid. Raises if not found."
  @spec get!(UUIDv7.t() | String.t(), keyword()) :: Department.t()
  def get!(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    Department
    |> preload(^preload)
    |> repo().get!(uuid)
  end

  @doc "Fetches a department by uuid, or `nil` if not found."
  @spec get(UUIDv7.t() | String.t(), keyword()) :: Department.t() | nil
  def get(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    Department
    |> preload(^preload)
    |> repo().get(uuid)
  end

  @doc "Returns a changeset for the given department."
  @spec change(Department.t(), map()) :: Ecto.Changeset.t(Department.t())
  def change(%Department{} = dept, attrs \\ %{}),
    do: Department.changeset(dept, attrs)

  @doc "Inserts a department and broadcasts `:department_created`."
  @spec create(map()) ::
          {:ok, Department.t()} | {:error, Ecto.Changeset.t(Department.t())}
  def create(attrs) do
    with {:ok, dept} <- %Department{} |> Department.changeset(attrs) |> repo().insert() do
      StaffPubSub.broadcast_department(:department_created, %{uuid: dept.uuid, name: dept.name})
      {:ok, dept}
    end
  end

  @doc "Updates a department and broadcasts `:department_updated`."
  @spec update(Department.t(), map()) ::
          {:ok, Department.t()} | {:error, Ecto.Changeset.t(Department.t())}
  def update(%Department{} = dept, attrs) do
    with {:ok, updated} <- dept |> Department.changeset(attrs) |> repo().update() do
      StaffPubSub.broadcast_department(:department_updated, %{
        uuid: updated.uuid,
        name: updated.name
      })

      {:ok, updated}
    end
  end

  @doc "Deletes a department and broadcasts `:department_deleted`."
  @spec delete(Department.t()) ::
          {:ok, Department.t()} | {:error, Ecto.Changeset.t(Department.t())}
  def delete(%Department{} = dept) do
    with {:ok, deleted} <- repo().delete(dept) do
      StaffPubSub.broadcast_department(:department_deleted, %{
        uuid: deleted.uuid,
        name: deleted.name
      })

      {:ok, deleted}
    end
  end

  @doc "Total number of departments."
  @spec count() :: non_neg_integer()
  def count, do: repo().aggregate(Department, :count, :uuid)
end
