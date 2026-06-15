defmodule PhoenixKitStaff.Skills do
  @moduledoc """
  Skills: CRUD for the `Skill` taxonomy plus person↔skill assignment
  (with proficiency level).

  Skill CRUD mirrors `PhoenixKitStaff.Teams`. The assignment functions
  (`assign_skill`/`unassign_skill`/…) live here for cohesion — note this
  deviates from team membership, which lives in `PhoenixKitStaff.Staff`;
  thin delegators are exposed there (`Staff.assign_skill/3`, etc.) so both
  context boundaries reach it.
  """

  import Ecto.Query

  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Person, PersonSkill, Skill}

  # Soft-delete sentinel — mirrors `Person.soft_delete_status/0`; skill
  # rosters exclude trashed people (the assignment row survives a trash).
  @soft_delete_status "trashed"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── Skill CRUD ─────────────────────────────────────────────────────

  @doc "Lists skills ordered by name. Accepts `:preload`."
  @spec list(keyword()) :: [Skill.t()]
  def list(opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    Skill
    |> order_by([s], asc: s.name)
    |> preload(^preload)
    |> repo().all()
  end

  @doc "Map of `skill_uuid => assigned-people count` (one query, for the list view)."
  @spec person_counts() :: %{optional(UUIDv7.t()) => non_neg_integer()}
  def person_counts do
    PersonSkill
    |> group_by([ps], ps.skill_uuid)
    |> select([ps], {ps.skill_uuid, count(ps.uuid)})
    |> repo().all()
    |> Map.new()
  end

  @doc "Fetches a skill by uuid. Raises if not found."
  @spec get!(UUIDv7.t() | String.t(), keyword()) :: Skill.t()
  def get!(uuid, opts \\ []) do
    Skill |> preload(^Keyword.get(opts, :preload, [])) |> repo().get!(uuid)
  end

  @doc "Fetches a skill by uuid, or `nil` if not found."
  @spec get(UUIDv7.t() | String.t(), keyword()) :: Skill.t() | nil
  def get(uuid, opts \\ []) do
    Skill |> preload(^Keyword.get(opts, :preload, [])) |> repo().get(uuid)
  end

  @doc "Returns a changeset for the given skill."
  @spec change(Skill.t(), map()) :: Ecto.Changeset.t(Skill.t())
  def change(%Skill{} = skill, attrs \\ %{}), do: Skill.changeset(skill, attrs)

  @doc "Inserts a skill and broadcasts `:skill_created`."
  @spec create(map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t(Skill.t())}
  def create(attrs) do
    with {:ok, skill} <- %Skill{} |> Skill.changeset(attrs) |> repo().insert() do
      StaffPubSub.broadcast_skill(:skill_created, %{uuid: skill.uuid, name: skill.name})
      {:ok, skill}
    end
  end

  @doc """
  Updates a skill and broadcasts `:skill_updated`.

  Reconciles existing assignments to the new `levels`/`allow_multiple_levels`
  **in the same transaction**: ids removed from `levels` are stripped from every
  `person_skills.proficiency_levels`, and if multiple→single each assignment is
  pruned to its first level (in skill order). This keeps assignments free of
  orphaned or over-count ids.
  """
  @spec update(Skill.t(), map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t(Skill.t())}
  def update(%Skill{} = skill, attrs) do
    result =
      repo().transaction(fn ->
        case skill |> Skill.changeset(attrs) |> repo().update() do
          {:ok, updated} ->
            reconcile_assignments(updated)
            updated

          {:error, cs} ->
            repo().rollback(cs)
        end
      end)

    case result do
      {:ok, updated} ->
        StaffPubSub.broadcast_skill(:skill_updated, %{uuid: updated.uuid, name: updated.name})
        {:ok, updated}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # Strip ids no longer in the skill's levels from every assignment, reorder to
  # skill-levels order, and prune to ≤1 when the skill is single-select. Only
  # touches rows that actually change.
  defp reconcile_assignments(%Skill{} = skill) do
    valid_ids = Skill.level_ids(skill)
    single? = not skill.allow_multiple_levels

    PersonSkill
    |> where([ps], ps.skill_uuid == ^skill.uuid)
    |> repo().all()
    |> Enum.each(fn ps ->
      kept = Enum.filter(valid_ids, &(&1 in (ps.proficiency_levels || [])))
      kept = if single?, do: Enum.take(kept, 1), else: kept

      if kept != (ps.proficiency_levels || []) do
        ps |> Ecto.Changeset.change(proficiency_levels: kept) |> repo().update!()
      end
    end)
  end

  @doc "Deletes a skill (cascades its assignments) and broadcasts `:skill_deleted`."
  @spec delete(Skill.t()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t(Skill.t())}
  def delete(%Skill{} = skill) do
    with {:ok, deleted} <- repo().delete(skill) do
      StaffPubSub.broadcast_skill(:skill_deleted, %{uuid: deleted.uuid, name: deleted.name})
      {:ok, deleted}
    end
  end

  @doc "Total number of skills."
  @spec count() :: non_neg_integer()
  def count, do: repo().aggregate(Skill, :count, :uuid)

  # ── Assignment (person ↔ skill + proficiency level) ────────────────

  @doc """
  Assigns a skill to a person at zero or more of the skill's levels (a list of
  level ids); broadcasts `:person_skill_added`. Validates the ids against the
  skill (must exist; ≤1 unless the skill allows multiple).
  """
  @spec assign_skill(
          UUIDv7.t() | String.t(),
          UUIDv7.t() | String.t(),
          [String.t()] | String.t() | nil
        ) ::
          {:ok, PersonSkill.t()}
          | {:error, :skill_not_found | :invalid_levels | :too_many_levels | Ecto.Changeset.t()}
  def assign_skill(person_uuid, skill_uuid, level_ids \\ []) do
    with skill when not is_nil(skill) <- get(skill_uuid),
         {:ok, normalized} <- validate_level_ids(skill, List.wrap(level_ids)),
         {:ok, ps} <-
           %PersonSkill{}
           |> PersonSkill.changeset(%{
             staff_person_uuid: person_uuid,
             skill_uuid: skill_uuid,
             proficiency_levels: normalized
           })
           |> repo().insert() do
      broadcast_person_skill(:person_skill_added, ps)
      {:ok, ps}
    else
      nil -> {:error, :skill_not_found}
      other -> other
    end
  end

  @doc """
  Replaces an assignment's selected levels (a list of level ids); broadcasts
  `:person_skill_updated`. Validates against the parent skill.
  """
  @spec update_assignment_levels(PersonSkill.t(), [String.t()] | String.t() | nil) ::
          {:ok, PersonSkill.t()}
          | {:error, :skill_not_found | :invalid_levels | :too_many_levels | Ecto.Changeset.t()}
  def update_assignment_levels(%PersonSkill{} = ps, level_ids) do
    with skill when not is_nil(skill) <- get(ps.skill_uuid),
         {:ok, normalized} <- validate_level_ids(skill, List.wrap(level_ids)),
         {:ok, updated} <-
           ps |> PersonSkill.changeset(%{proficiency_levels: normalized}) |> repo().update() do
      broadcast_person_skill(:person_skill_updated, updated)
      {:ok, updated}
    else
      nil -> {:error, :skill_not_found}
      other -> other
    end
  end

  @doc """
  Validates a list of level ids against a skill: every id must exist in the
  skill's `levels`, and there must be ≤1 unless `allow_multiple_levels`. Returns
  the ids cleaned + reordered to the skill's level order on success.
  """
  @spec validate_level_ids(Skill.t(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, :invalid_levels | :too_many_levels}
  def validate_level_ids(%Skill{} = skill, ids) when is_list(ids) do
    # Reject non-binary ids outright rather than `to_string/1`-crashing on a
    # crafted param (a map/tuple in the list).
    if Enum.all?(ids, &is_binary/1) do
      cleaned =
        ids
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      allowed = Skill.level_ids(skill)

      cond do
        not Enum.all?(cleaned, &(&1 in allowed)) -> {:error, :invalid_levels}
        not skill.allow_multiple_levels and length(cleaned) > 1 -> {:error, :too_many_levels}
        true -> {:ok, Enum.filter(allowed, &(&1 in cleaned))}
      end
    else
      {:error, :invalid_levels}
    end
  end

  def validate_level_ids(%Skill{}, _ids), do: {:error, :invalid_levels}

  @doc "Removes an assignment (by struct or person/skill uuids); broadcasts `:person_skill_removed`."
  @spec unassign_skill(PersonSkill.t()) ::
          {:ok, PersonSkill.t()} | {:error, Ecto.Changeset.t(PersonSkill.t())}
  @spec unassign_skill(UUIDv7.t() | String.t(), UUIDv7.t() | String.t()) ::
          {:ok, PersonSkill.t()}
          | {:error, :not_found}
          | {:error, Ecto.Changeset.t(PersonSkill.t())}
  def unassign_skill(%PersonSkill{} = ps) do
    with {:ok, deleted} <- repo().delete(ps) do
      broadcast_person_skill(:person_skill_removed, deleted)
      {:ok, deleted}
    end
  end

  def unassign_skill(person_uuid, skill_uuid) do
    case repo().get_by(PersonSkill, staff_person_uuid: person_uuid, skill_uuid: skill_uuid) do
      nil -> {:error, :not_found}
      ps -> unassign_skill(ps)
    end
  end

  @doc "A person's skill assignments, skill preloaded, ordered by skill name."
  @spec list_for_person(UUIDv7.t() | String.t()) :: [PersonSkill.t()]
  def list_for_person(person_uuid) do
    PersonSkill
    |> join(:inner, [ps], s in assoc(ps, :skill))
    |> where([ps], ps.staff_person_uuid == ^person_uuid)
    |> order_by([ps, s], asc: s.name)
    |> preload([ps, s], skill: s)
    |> repo().all()
  end

  @doc """
  People assigned a given skill, person + user preloaded. Trashed people
  are excluded (the assignment row survives a trash; restore brings them back).
  """
  @spec list_people_for_skill(UUIDv7.t() | String.t()) :: [PersonSkill.t()]
  def list_people_for_skill(skill_uuid) do
    PersonSkill
    |> join(:inner, [ps], p in assoc(ps, :staff_person))
    |> where([ps, p], ps.skill_uuid == ^skill_uuid and p.status != ^@soft_delete_status)
    |> preload([ps, p], staff_person: [:user])
    |> order_by([ps], asc: ps.inserted_at)
    |> repo().all()
  end

  @doc "Non-trashed people not yet assigned this skill (for the add picker)."
  @spec people_without_skill(UUIDv7.t() | String.t()) :: [Person.t()]
  def people_without_skill(skill_uuid) do
    assigned =
      from(ps in PersonSkill,
        where: ps.skill_uuid == ^skill_uuid,
        select: ps.staff_person_uuid
      )

    from(p in Person,
      where: p.uuid not in subquery(assigned) and p.status != ^@soft_delete_status,
      preload: [:user],
      order_by: [asc: p.inserted_at]
    )
    |> repo().all()
  end

  @doc "Skills not yet assigned to a person, ordered by name (for the person-side add picker)."
  @spec skills_not_assigned_to(UUIDv7.t() | String.t()) :: [Skill.t()]
  def skills_not_assigned_to(person_uuid) do
    assigned =
      from(ps in PersonSkill,
        where: ps.staff_person_uuid == ^person_uuid,
        select: ps.skill_uuid
      )

    from(s in Skill, where: s.uuid not in subquery(assigned), order_by: [asc: s.name])
    |> repo().all()
  end

  defp broadcast_person_skill(event, %PersonSkill{} = ps) do
    StaffPubSub.broadcast_person_skill(event, %{
      skill_uuid: ps.skill_uuid,
      staff_person_uuid: ps.staff_person_uuid,
      uuid: ps.uuid
    })
  end
end
