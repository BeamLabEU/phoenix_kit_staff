defmodule PhoenixKitStaff.Schemas.Department do
  @moduledoc "Top-level organizational unit containing teams."

  use Ecto.Schema
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Changeset

  alias PhoenixKitStaff.Schemas.Team

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_staff_departments" do
    field(:name, :string)
    field(:description, :string)

    has_many(:teams, Team, foreign_key: :department_uuid, on_delete: :delete_all)

    timestamps(type: :utc_datetime)
  end

  @required ~w(name)a
  @optional ~w(description)a

  def changeset(dept, attrs) do
    dept
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:name,
      name: :phoenix_kit_staff_departments_name_index,
      message: gettext("already taken")
    )
  end
end
