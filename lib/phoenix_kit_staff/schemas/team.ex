defmodule PhoenixKitStaff.Schemas.Team do
  @moduledoc "A team inside a department."

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.Schemas.{Department, TeamMembership}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          department_uuid: UUIDv7.t() | nil,
          department: Department.t() | Ecto.Association.NotLoaded.t() | nil,
          team_memberships: [TeamMembership.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_teams" do
    field(:name, :string)
    field(:description, :string)

    belongs_to(:department, Department, foreign_key: :department_uuid, references: :uuid)
    has_many(:team_memberships, TeamMembership, foreign_key: :team_uuid, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @required ~w(name department_uuid)a
  @optional ~w(description)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(team, attrs) do
    team
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:department)
    |> unique_constraint([:department_uuid, :name],
      name: :phoenix_kit_staff_teams_department_name_index,
      message: gettext("already taken in this department")
    )
  end
end
