defmodule PhoenixKitStaff.Employments do
  @moduledoc """
  Employment history for staff people (core V136) — the **sole write path** for
  `PhoenixKitStaff.Schemas.Employment` spans.

  A person has a timeline of spans; the **open** span (no end date) is the
  current employment. This context:

    * keeps the **one-open-span-per-person** invariant — `create/2` closes the
      prior open span when a new open one starts (the DB partial-unique index
      backstops it);
    * **denormalizes the current span onto `Person`** via `sync_current/1`, run
      in the same transaction as every mutation, so existing readers (overview
      org tree → `primary_department_uuid`, people list → `job_title`) need no
      join and stay consistent;
    * broadcasts `:person_employment_changed` on the person's topic so the
      profile view refreshes.

  `job_title` is translatable; `sync_current/1` mirrors the current span's
  `job_title` + its per-locale overrides onto `Person` without clobbering the
  person's other translated fields (`bio`, `notes`).
  """

  # `except: [update: 2]` — Ecto.Query exports an `update/2` macro that would
  # shadow this context's own `update/2` (used by `end_span/2`). We use
  # `repo().update/1` for writes, never the query macro.
  import Ecto.Query, except: [update: 2]

  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Employment, Person}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── Reads ──────────────────────────────────────────────────────────

  @doc "A person's employment spans, current/open first then newest-first, dept+team preloaded."
  @spec list_for_person(UUIDv7.t() | String.t()) :: [Employment.t()]
  def list_for_person(person_uuid) do
    Employment
    |> where([e], e.staff_person_uuid == ^person_uuid)
    |> order_by([e],
      asc: fragment("(? IS NOT NULL)", e.employment_end_date),
      desc_nulls_last: e.employment_start_date,
      desc: e.inserted_at
    )
    |> preload([:department, :team])
    |> repo().all()
  end

  @doc "The current span (open if any, else the latest by start), dept+team preloaded, or nil."
  @spec current_for_person(UUIDv7.t() | String.t()) :: Employment.t() | nil
  def current_for_person(person_uuid) do
    case open_span(person_uuid) || latest_span(person_uuid) do
      nil -> nil
      span -> repo().preload(span, [:department, :team])
    end
  end

  @doc "Fetches a span by uuid, or nil."
  @spec get(UUIDv7.t() | String.t()) :: Employment.t() | nil
  def get(uuid), do: repo().get(Employment, uuid)

  # ── Writes ─────────────────────────────────────────────────────────

  @doc """
  Creates an employment span for a person and denormalizes the current span
  onto `Person`. If the new span is **open** (no end date) and an open span
  already exists, the prior open span is closed at the new span's start date
  (today if it has none) so the one-open invariant holds.
  """
  @spec create(UUIDv7.t() | String.t(), map()) ::
          {:ok, Employment.t()} | {:error, Ecto.Changeset.t(Employment.t())}
  def create(person_uuid, attrs) do
    cs = Employment.changeset(%Employment{}, Map.put(attrs, "staff_person_uuid", person_uuid))

    repo().transaction(fn ->
      # Closing the prior open span first keeps the partial-unique index happy;
      # an invalid insert rolls the close back with the transaction.
      if is_nil(Ecto.Changeset.get_field(cs, :employment_end_date)) do
        close_open_span(
          person_uuid,
          Ecto.Changeset.get_field(cs, :employment_start_date) || Date.utc_today()
        )
      end

      case repo().insert(cs) do
        {:ok, span} ->
          sync_current(person_uuid)
          span

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
    |> finalize(person_uuid)
  end

  @doc "Updates a span and re-denormalizes the current span onto `Person`."
  @spec update(Employment.t(), map()) ::
          {:ok, Employment.t()} | {:error, Ecto.Changeset.t(Employment.t())}
  def update(%Employment{} = span, attrs) do
    repo().transaction(fn ->
      case span |> Employment.changeset(attrs) |> repo().update() do
        {:ok, updated} ->
          sync_current(updated.staff_person_uuid)
          updated

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
    |> finalize(span.staff_person_uuid)
  end

  @doc "Ends an open span by setting its end date (then re-syncs)."
  @spec end_span(Employment.t(), Date.t() | String.t()) ::
          {:ok, Employment.t()} | {:error, Ecto.Changeset.t(Employment.t())}
  def end_span(%Employment{} = span, end_date),
    do: update(span, %{"employment_end_date" => end_date})

  @doc "Deletes a span and re-denormalizes the current span onto `Person`."
  @spec delete(Employment.t()) ::
          {:ok, Employment.t()} | {:error, Ecto.Changeset.t(Employment.t())}
  def delete(%Employment{} = span) do
    repo().transaction(fn ->
      {:ok, deleted} = repo().delete(span)
      sync_current(span.staff_person_uuid)
      deleted
    end)
    |> finalize(span.staff_person_uuid)
  end

  @doc """
  Recomputes the person's current span (open, else latest) and writes the
  denormalized mirror onto `Person` (`employment_type`, `job_title` + its
  translations, dates, `primary_department_uuid`, `work_location`) — clearing
  them when the person has no spans. Server-owned: never cast from the form.
  Call inside the mutating transaction.
  """
  @spec sync_current(UUIDv7.t() | String.t()) :: :ok
  def sync_current(person_uuid) do
    case repo().get(Person, person_uuid) do
      nil ->
        :ok

      person ->
        span = open_span(person_uuid) || latest_span(person_uuid)
        person |> Ecto.Changeset.change(mirror_attrs(span, person)) |> repo().update!()
        :ok
    end
  end

  # ── Internals ──────────────────────────────────────────────────────

  defp open_span(person_uuid) do
    Employment
    |> where([e], e.staff_person_uuid == ^person_uuid and is_nil(e.employment_end_date))
    |> repo().one()
  end

  defp latest_span(person_uuid) do
    Employment
    |> where([e], e.staff_person_uuid == ^person_uuid)
    |> order_by([e], desc_nulls_last: e.employment_start_date, desc: e.inserted_at)
    |> limit(1)
    |> repo().one()
  end

  defp close_open_span(person_uuid, end_date) do
    case open_span(person_uuid) do
      nil -> :ok
      prior -> prior |> Ecto.Changeset.change(employment_end_date: end_date) |> repo().update!()
    end
  end

  defp mirror_attrs(nil, person) do
    %{
      employment_type: nil,
      job_title: nil,
      employment_start_date: nil,
      employment_end_date: nil,
      primary_department_uuid: nil,
      work_location: nil,
      translations: merge_job_title_translations(person.translations || %{}, %{})
    }
  end

  defp mirror_attrs(%Employment{} = span, person) do
    %{
      employment_type: span.employment_type,
      job_title: span.job_title,
      employment_start_date: span.employment_start_date,
      employment_end_date: span.employment_end_date,
      primary_department_uuid: span.primary_department_uuid,
      work_location: span.work_location,
      translations:
        merge_job_title_translations(person.translations || %{}, span.translations || %{})
    }
  end

  # Set/clear each language's `job_title` from the span's translations while
  # preserving the person's other translated fields (bio, notes). Drops langs
  # that end up empty.
  defp merge_job_title_translations(person_tr, span_tr) do
    (Map.keys(person_tr) ++ Map.keys(span_tr))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn lang, acc ->
      person_sub = Map.get(person_tr, lang, %{})
      span_title = span_tr |> Map.get(lang, %{}) |> Map.get("job_title")

      sub =
        case span_title do
          v when is_binary(v) and v != "" -> Map.put(person_sub, "job_title", v)
          _ -> Map.delete(person_sub, "job_title")
        end

      if map_size(sub) == 0, do: acc, else: Map.put(acc, lang, sub)
    end)
  end

  defp finalize({:ok, record}, person_uuid) do
    StaffPubSub.broadcast_person(:person_employment_changed, %{uuid: person_uuid})
    {:ok, record}
  end

  defp finalize({:error, reason}, _person_uuid), do: {:error, reason}
end
