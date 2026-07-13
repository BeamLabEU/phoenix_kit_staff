defmodule PhoenixKitStaff.Schemas.Employment do
  @moduledoc """
  One span in a staff person's **employment history** (core V136).

  Each row records an employment period: the `employment_type`, a translatable
  `job_title`, the org placement at the time (`primary_department_uuid` plus a
  `primary_team_uuid` snapshot), the date range (`employment_end_date` `nil` =
  the **open/current** span), `work_location`, and free-text `notes`.

  The DB enforces **at most one open span per person** (partial unique index on
  `staff_person_uuid WHERE employment_end_date IS NULL`); `PhoenixKitStaff.Employments`
  is the sole write path and closes the prior open span when a new one starts,
  then denormalizes the current span onto `Person` (`sync_current/1`).

  `job_title` is translatable (same `translations` JSONB shape as `Person`/`Skill`).
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.L10n
  alias PhoenixKitStaff.Schemas.{Department, Person, Team}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @translatable_fields ~w(job_title)

  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          staff_person_uuid: UUIDv7.t() | nil,
          person: Person.t() | Ecto.Association.NotLoaded.t() | nil,
          employment_type: String.t() | nil,
          job_title: String.t() | nil,
          translations: translations_map(),
          primary_department_uuid: UUIDv7.t() | nil,
          department: Department.t() | Ecto.Association.NotLoaded.t() | nil,
          primary_team_uuid: UUIDv7.t() | nil,
          team: Team.t() | Ecto.Association.NotLoaded.t() | nil,
          employment_start_date: Date.t() | nil,
          employment_end_date: Date.t() | nil,
          work_location: String.t() | nil,
          notes: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_employments" do
    field(:employment_type, :string)
    field(:job_title, :string)
    field(:translations, :map, default: %{})
    field(:employment_start_date, :date)
    field(:employment_end_date, :date)
    field(:work_location, :string)
    field(:notes, :string)

    belongs_to(:person, Person, foreign_key: :staff_person_uuid, references: :uuid)
    belongs_to(:department, Department, foreign_key: :primary_department_uuid, references: :uuid)
    belongs_to(:team, Team, foreign_key: :primary_team_uuid, references: :uuid)

    timestamps(type: :utc_datetime)
  end

  @required ~w(staff_person_uuid)a
  @optional ~w(employment_type job_title translations primary_department_uuid
               primary_team_uuid employment_start_date employment_end_date
               work_location notes)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(employment, attrs) do
    employment
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    # Reuses Person's enum + message (same backend → same translation).
    |> validate_inclusion(:employment_type, Person.employment_types(),
      message:
        gettext("must be one of: %{values}", values: Enum.join(Person.employment_types(), ", "))
    )
    |> validate_length(:job_title, max: 255)
    |> validate_length(:work_location, max: 255)
    |> validate_dates()
    |> L10n.validate_translations()
    |> assoc_constraint(:person)
    |> foreign_key_constraint(:primary_department_uuid)
    |> foreign_key_constraint(:primary_team_uuid)
    # Backstops the partial-unique index (≤1 open span/person) so reopening a
    # span while another is open surfaces as a changeset error, not a raise.
    # The `Employments` create path auto-closes the prior open span first.
    |> unique_constraint(:employment_end_date,
      name: :phoenix_kit_staff_employments_one_open_index,
      message: gettext("there is already a current (open) employment")
    )
  end

  # End must be on or after start when both are set.
  defp validate_dates(changeset) do
    start = get_field(changeset, :employment_start_date)
    finish = get_field(changeset, :employment_end_date)

    if start && finish && Date.compare(finish, start) == :lt do
      add_error(changeset, :employment_end_date, gettext("must be on or after the start date"))
    else
      changeset
    end
  end

  @doc "Whether this span is the open/current one (no end date)."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{employment_end_date: nil}), do: true
  def open?(%__MODULE__{}), do: false

  @doc "DB-column field names that participate in the `translations` JSONB."
  @spec translatable_fields() :: [String.t()]
  def translatable_fields, do: @translatable_fields

  @doc "Translated `job_title` in `lang` (primary-column fallback)."
  @spec localized_job_title(t(), String.t() | nil) :: String.t() | nil
  def localized_job_title(%__MODULE__{} = e, lang), do: L10n.localized_field(e, "job_title", lang)
end
