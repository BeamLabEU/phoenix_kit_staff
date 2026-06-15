defmodule PhoenixKitStaff.Staff.Memberships do
  @moduledoc """
  Team membership management — the person ↔ team join.

  Extracted from `PhoenixKitStaff.Staff`, which keeps thin delegators
  (`Staff.add_team_person/2`, `Staff.list_team_memberships/1`, …) so the public
  API is unchanged. Rosters exclude trashed people — the membership row
  survives a trash, so restoring the person brings them back.
  """

  import Ecto.Query

  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Person, TeamMembership}

  # Soft-delete sentinel — mirrors `Person.soft_delete_status/0`.
  @soft_delete_status "trashed"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc """
  Memberships on a given team, preloaded with staff_person and user.
  Trashed people are excluded — the team roster shows the active members
  only (the membership row survives a trash, so restore brings them back).
  """
  @spec list_team_memberships(UUIDv7.t() | String.t()) :: [TeamMembership.t()]
  def list_team_memberships(team_uuid) do
    TeamMembership
    |> join(:inner, [tm], p in assoc(tm, :staff_person))
    |> where([tm, p], tm.team_uuid == ^team_uuid and p.status != ^@soft_delete_status)
    |> preload(staff_person: [:user])
    |> order_by([tm], asc: tm.inserted_at)
    |> repo().all()
  end

  @doc "All memberships a given person belongs to, with team and department preloaded."
  @spec list_memberships_for_person(UUIDv7.t() | String.t()) :: [TeamMembership.t()]
  def list_memberships_for_person(person_uuid) do
    TeamMembership
    |> where([tm], tm.staff_person_uuid == ^person_uuid)
    |> preload(team: [:department])
    |> order_by([tm], asc: tm.inserted_at)
    |> repo().all()
  end

  @doc "Adds a person to a team and broadcasts `:team_person_added`."
  @spec add_team_person(UUIDv7.t() | String.t(), UUIDv7.t() | String.t()) ::
          {:ok, TeamMembership.t()} | {:error, Ecto.Changeset.t(TeamMembership.t())}
  def add_team_person(team_uuid, staff_person_uuid) do
    with {:ok, tm} <-
           %TeamMembership{}
           |> TeamMembership.changeset(%{
             team_uuid: team_uuid,
             staff_person_uuid: staff_person_uuid
           })
           |> repo().insert() do
      StaffPubSub.broadcast_team_membership(:team_person_added, %{
        team_uuid: tm.team_uuid,
        staff_person_uuid: tm.staff_person_uuid,
        uuid: tm.uuid
      })

      {:ok, tm}
    end
  end

  @doc "Removes a team membership (by struct or by team/person uuids) and broadcasts `:team_person_removed`."
  @spec remove_team_person(TeamMembership.t()) ::
          {:ok, TeamMembership.t()} | {:error, Ecto.Changeset.t(TeamMembership.t())}
  @spec remove_team_person(UUIDv7.t() | String.t(), UUIDv7.t() | String.t()) ::
          {:ok, TeamMembership.t()}
          | {:error, Ecto.Changeset.t(TeamMembership.t())}
          | {:error, :not_found}
  def remove_team_person(%TeamMembership{} = tm) do
    with {:ok, deleted} <- repo().delete(tm) do
      StaffPubSub.broadcast_team_membership(:team_person_removed, %{
        team_uuid: deleted.team_uuid,
        staff_person_uuid: deleted.staff_person_uuid,
        uuid: deleted.uuid
      })

      {:ok, deleted}
    end
  end

  def remove_team_person(team_uuid, staff_person_uuid) do
    case repo().get_by(TeamMembership, team_uuid: team_uuid, staff_person_uuid: staff_person_uuid) do
      nil -> {:error, :not_found}
      tm -> remove_team_person(tm)
    end
  end

  @doc "People not already on this team (for the add-to-team picker)."
  @spec people_not_on_team(UUIDv7.t() | String.t()) :: [Person.t()]
  def people_not_on_team(team_uuid) do
    person_uuids_on_team =
      from(tm in TeamMembership,
        where: tm.team_uuid == ^team_uuid,
        select: tm.staff_person_uuid
      )

    from(p in Person,
      where:
        p.uuid not in subquery(person_uuids_on_team) and
          p.status != ^@soft_delete_status,
      preload: [:user],
      order_by: [asc: p.inserted_at]
    )
    |> repo().all()
  end
end
