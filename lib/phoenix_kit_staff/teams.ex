defmodule PhoenixKitStaff.Teams do
  @moduledoc "CRUD for teams."

  import Ecto.Query

  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Team

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Lists teams. Accepts `:preload` and `:department_uuid` to filter by department."
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
  def get!(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:department])

    Team
    |> preload(^preload)
    |> repo().get!(uuid)
  end

  @doc "Fetches a team by uuid, or `nil` if not found."
  def get(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:department])

    Team
    |> preload(^preload)
    |> repo().get(uuid)
  end

  @doc "Returns a changeset for the given team."
  def change(%Team{} = team, attrs \\ %{}), do: Team.changeset(team, attrs)

  @doc "Inserts a team and broadcasts `:team_created`."
  def create(attrs) do
    with {:ok, team} <- %Team{} |> Team.changeset(attrs) |> repo().insert() do
      broadcast(team, :team_created)
      {:ok, team}
    end
  end

  @doc "Updates a team and broadcasts `:team_updated`."
  def update(%Team{} = team, attrs) do
    with {:ok, updated} <- team |> Team.changeset(attrs) |> repo().update() do
      broadcast(updated, :team_updated)
      {:ok, updated}
    end
  end

  @doc "Deletes a team and broadcasts `:team_deleted`."
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
  def count, do: repo().aggregate(Team, :count, :uuid)
end
