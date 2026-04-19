defmodule PhoenixKitStaff.Schemas.TeamMembership do
  @moduledoc "Join between `Team` and `Person` — represents a person's membership on a team."

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.Schemas.{Person, Team}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_staff_team_memberships" do
    belongs_to(:team, Team, foreign_key: :team_uuid, references: :uuid)

    belongs_to(:staff_person, Person,
      foreign_key: :staff_person_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w(team_uuid staff_person_uuid)a

  def changeset(tm, attrs) do
    tm
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> assoc_constraint(:team)
    |> assoc_constraint(:staff_person)
    |> unique_constraint([:team_uuid, :staff_person_uuid],
      name: :phoenix_kit_staff_team_memberships_team_person_index,
      message: gettext("already on this team")
    )
  end
end
