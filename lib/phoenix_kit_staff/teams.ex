defmodule PhoenixKitStaff.Teams do
  @moduledoc "CRUD for teams."

  import Ecto.Query

  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Team

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Lists teams. Accepts `:preload` and `:department_uuid` to filter by department."
  @spec list(keyword()) :: [Team.t()]
  def list(opts \\ []) do
    preload = Keyword.get(opts, :preload, [:department])
    department_uuid = Keyword.get(opts, :department_uuid)

    Team
    |> maybe_by_department(department_uuid)
    |> order_by([t], asc: t.name)
    |> preload(^preload)
    |> repo().all()
  end

  defp maybe_by_department(query, nil), do: query
  defp maybe_by_department(query, uuid), do: where(query, [t], t.department_uuid == ^uuid)

  @doc "Fetches a team by uuid. Raises if not found."
  @spec get!(UUIDv7.t() | String.t(), keyword()) :: Team.t()
  def get!(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:department])

    Team
    |> preload(^preload)
    |> repo().get!(uuid)
  end

  @doc "Fetches a team by uuid, or `nil` if not found."
  @spec get(UUIDv7.t() | String.t(), keyword()) :: Team.t() | nil
  def get(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:department])

    Team
    |> preload(^preload)
    |> repo().get(uuid)
  end

  @doc "Returns a changeset for the given team."
  @spec change(Team.t(), map()) :: Ecto.Changeset.t(Team.t())
  def change(%Team{} = team, attrs \\ %{}), do: Team.changeset(team, attrs)

  @doc "Inserts a team and broadcasts `:team_created`."
  @spec create(map()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t(Team.t())}
  def create(attrs) do
    with {:ok, team} <- %Team{} |> Team.changeset(attrs) |> repo().insert() do
      broadcast(team, :team_created)
      {:ok, team}
    end
  end

  @doc "Updates a team and broadcasts `:team_updated`."
  @spec update(Team.t(), map()) ::
          {:ok, Team.t()} | {:error, Ecto.Changeset.t(Team.t())}
  def update(%Team{} = team, attrs) do
    with {:ok, updated} <- team |> Team.changeset(attrs) |> repo().update() do
      broadcast(updated, :team_updated)
      {:ok, updated}
    end
  end

  @doc "Deletes a team and broadcasts `:team_deleted`."
  @spec delete(Team.t()) :: {:ok, Team.t()} | {:error, Ecto.Changeset.t(Team.t())}
  def delete(%Team{} = team) do
    with {:ok, deleted} <- repo().delete(team) do
      broadcast(deleted, :team_deleted)
      {:ok, deleted}
    end
  end

  defp broadcast(team, event) do
    StaffPubSub.broadcast_team(event, %{
      uuid: team.uuid,
      name: team.name,
      department_uuid: team.department_uuid
    })
  end

  @doc "Total number of teams."
  @spec count() :: non_neg_integer()
  def count, do: repo().aggregate(Team, :count, :uuid)
end
