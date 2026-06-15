defmodule PhoenixKitStaff.DataCase do
  @moduledoc """
  Test case for tests that hit the database.

  Uses `PhoenixKitStaff.Test.Repo` with SQL Sandbox for per-test isolation.
  Tests using this case are tagged `:integration` and are automatically
  excluded when the database is unavailable (see `test/test_helper.exs`).

  ## Usage

      defmodule PhoenixKitStaff.Integration.SomethingTest do
        use PhoenixKitStaff.DataCase, async: true

        test "creates a record" do
          # Repo is available here; transactions are isolated.
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitStaff.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitStaff.ActivityLogAssertions
      import PhoenixKitStaff.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitStaff.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc """
  Transforms changeset errors into a map of field → [message] for easy assertions.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── Fixtures (shared between DataCase and LiveCase consumers) ────

  @doc "Creates a Department with a unique name."
  def fixture_department(attrs \\ %{}) do
    {:ok, dept} =
      PhoenixKitStaff.Departments.create(
        Map.merge(%{"name" => "Dept #{System.unique_integer([:positive])}"}, attrs)
      )

    dept
  end

  @doc "Creates a Team in the given (or fresh) department."
  def fixture_team(attrs \\ %{}) do
    dept_uuid = Map.get(attrs, "department_uuid") || fixture_department().uuid

    base = %{
      "name" => "Team #{System.unique_integer([:positive])}",
      "department_uuid" => dept_uuid
    }

    {:ok, team} = PhoenixKitStaff.Teams.create(Map.merge(base, attrs))
    team
  end

  @doc """
  Creates a placeholder user + linked Person fixture using the public
  `Staff.create_person_with_user/2` flow — same path the form LV
  exercises in production. The returned Person has `:user` preloaded
  so callers can pass `person.user` straight to
  `Staff.rename_placeholder_email/2`.
  """
  def fixture_person(attrs \\ %{}) do
    email = Map.get(attrs, "email") || "person-#{System.unique_integer([:positive])}@example.com"
    person_attrs = Map.drop(attrs, ["email"])

    {:ok, person, _user_status} =
      PhoenixKitStaff.Staff.create_person_with_user(email, person_attrs)

    PhoenixKitStaff.Staff.get_person!(person.uuid, preload: [:user, :primary_department])
  end

  @doc "Creates a Skill fixture (unique name unless overridden)."
  def fixture_skill(attrs \\ %{}) do
    {:ok, skill} =
      PhoenixKitStaff.Skills.create(
        Map.merge(%{"name" => "Skill #{System.unique_integer([:positive])}"}, attrs)
      )

    skill
  end

  @doc """
  Creates a Skill with one "Proficiency" selector holding the given option
  names (ids auto-generated). Returns `{skill, ids_by_name}` where
  `ids_by_name` maps each option name to its id. Pass
  `%{"allow_multiple" => true}` (or the legacy `%{"allow_multiple_levels" => true}`)
  in `attrs` to make the selector multi-select.
  """
  def fixture_skill_with_levels(option_names, attrs \\ %{}) do
    multiple = Map.get(attrs, "allow_multiple", Map.get(attrs, "allow_multiple_levels", false))
    rest = attrs |> Map.delete("allow_multiple") |> Map.delete("allow_multiple_levels")
    # Blank selector name → renders chips with no group label, matching the
    # legacy single-list UX (keeps web assertions on option text stable).
    fixture_skill_with_selectors([{"", multiple, option_names}], rest)
  end

  @doc """
  Creates a Skill with the given selectors. `selectors` is a list of
  `{name, allow_multiple, option_names}` tuples. Returns `{skill, ids_by_name}`
  where `ids_by_name` maps each option name to its id (option names must be
  unique across selectors).
  """
  def fixture_skill_with_selectors(selectors, attrs \\ %{}) do
    levels =
      Enum.map(selectors, fn {name, multiple, option_names} ->
        %{
          "name" => name,
          "allow_multiple" => multiple,
          "options" => Enum.map(option_names, &%{"name" => &1})
        }
      end)

    skill = fixture_skill(Map.merge(%{"levels" => levels}, attrs))

    ids_by_name =
      skill.levels
      |> Enum.flat_map(&Map.get(&1, "options", []))
      |> Map.new(fn o -> {o["name"], o["id"]} end)

    {skill, ids_by_name}
  end
end
