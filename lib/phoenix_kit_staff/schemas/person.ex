defmodule PhoenixKitStaff.Schemas.Person do
  @moduledoc """
  A person on staff. Always linked to a PhoenixKit user (decision A for MVP);
  the `user_uuid` FK is required.

  All profile fields beyond the required `user_uuid` and `status` are
  optional — fill in whatever's relevant.
  """

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitStaff.Schemas.{Department, TeamMembership}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive)
  @employment_types ~w(full_time part_time contractor intern temporary)

  schema "phoenix_kit_staff_people" do
    field(:status, :string, default: "active")
    field(:job_title, :string)
    field(:employment_type, :string)
    field(:employment_start_date, :date)
    field(:employment_end_date, :date)
    field(:work_location, :string)
    field(:work_phone, :string)
    field(:personal_phone, :string)
    field(:bio, :string)
    field(:skills, :string)
    field(:notes, :string)
    field(:date_of_birth, :date)
    field(:personal_email, :string)
    field(:emergency_contact_name, :string)
    field(:emergency_contact_phone, :string)
    field(:emergency_contact_relationship, :string)

    belongs_to(:user, User, foreign_key: :user_uuid, references: :uuid)

    belongs_to(:primary_department, Department,
      foreign_key: :primary_department_uuid,
      references: :uuid
    )

    has_many(:team_memberships, TeamMembership,
      foreign_key: :staff_person_uuid,
      on_delete: :delete_all
    )

    timestamps(type: :utc_datetime)
  end

  @required ~w(user_uuid status)a
  @optional ~w(primary_department_uuid job_title employment_type
               employment_start_date employment_end_date work_location
               work_phone personal_phone bio skills notes
               date_of_birth personal_email
               emergency_contact_name emergency_contact_phone
               emergency_contact_relationship)a

  def changeset(person, attrs) do
    person
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:employment_type, @employment_types,
      message: gettext("must be one of: %{values}", values: Enum.join(@employment_types, ", "))
    )
    |> validate_length(:job_title, max: 255)
    |> validate_length(:work_location, max: 255)
    |> validate_length(:work_phone, max: 50)
    |> validate_length(:personal_phone, max: 50)
    |> validate_length(:personal_email, max: 255)
    |> validate_format(:personal_email, PhoenixKitStaff.Staff.email_regex(),
      message: gettext("must be a valid email")
    )
    |> validate_length(:emergency_contact_name, max: 255)
    |> validate_length(:emergency_contact_phone, max: 50)
    |> validate_length(:emergency_contact_relationship, max: 100)
    |> assoc_constraint(:user)
    |> unique_constraint(:user_uuid, message: gettext("already linked to a person on staff"))
  end

  def statuses, do: @statuses
  def employment_types, do: @employment_types

  @doc "Translated label for a status value (for UI display)."
  def status_label("active"), do: gettext("Active")
  def status_label("inactive"), do: gettext("Inactive")
  def status_label(other), do: other

  def employment_type_label("full_time"), do: gettext("Full-time")
  def employment_type_label("part_time"), do: gettext("Part-time")
  def employment_type_label("contractor"), do: gettext("Contractor")
  def employment_type_label("intern"), do: gettext("Intern")
  def employment_type_label("temporary"), do: gettext("Temporary")
  def employment_type_label(nil), do: nil
  def employment_type_label(other), do: other

  @doc "Splits a comma-separated skills string into a list, trimming blanks."
  def skill_list(nil), do: []

  def skill_list(skills) when is_binary(skills) do
    skills
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
