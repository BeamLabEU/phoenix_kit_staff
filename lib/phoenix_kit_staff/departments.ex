defmodule PhoenixKitStaff.Departments do
  @moduledoc "CRUD for departments."

  import Ecto.Query

  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Department

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Lists departments. Accepts `:preload`."
  def list(opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    Department
    |> order_by([d], asc: d.name)
    |> preload(^preload)
    |> repo().all()
  end

  @doc "Fetches a department by uuid. Raises if not found."
  def get!(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    Department
    |> preload(^preload)
    |> repo().get!(uuid)
  end

  @doc "Fetches a department by uuid, or `nil` if not found."
  def get(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    Department
    |> preload(^preload)
    |> repo().get(uuid)
  end

  @doc "Returns a changeset for the given department."
  def change(%Department{} = dept, attrs \\ %{}),
    do: Department.changeset(dept, attrs)

  @doc "Inserts a department and broadcasts `:department_created`."
  def create(attrs) do
    with {:ok, dept} <- %Department{} |> Department.changeset(attrs) |> repo().insert() do
      StaffPubSub.broadcast_department(:department_created, %{uuid: dept.uuid, name: dept.name})
      {:ok, dept}
    end
  end

  @doc "Updates a department and broadcasts `:department_updated`."
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
  def count, do: repo().aggregate(Department, :count, :uuid)
end
