defmodule PhoenixKitStaff.ActivityLabels do
  @moduledoc """
  Maps staff activity action strings (e.g. `"staff.person_employment_added"`)
  to a `{heroicon, human_label}` pair for the person profile's **Events** tab.
  Domain labels go through `PhoenixKitStaff.Gettext`. Unknown actions fall back
  to a humanized form of the action string so a newly-added action still renders
  sensibly without a code change here.
  """

  use Gettext, backend: PhoenixKitStaff.Gettext

  @doc "Returns `{icon_name, label}` for an action string."
  @spec describe(String.t()) :: {String.t(), String.t()}
  def describe("staff.person_created"), do: {"hero-user-plus", gettext("Profile created")}
  def describe("staff.person_updated"), do: {"hero-pencil-square", gettext("Profile updated")}

  def describe("staff.person_deleted"),
    do: {"hero-x-circle", gettext("Profile permanently deleted")}

  def describe("staff.person_trashed"), do: {"hero-trash", gettext("Moved to trash")}

  def describe("staff.person_restored"),
    do: {"hero-arrow-uturn-left", gettext("Restored from trash")}

  def describe("staff.person_employment_added"),
    do: {"hero-briefcase", gettext("Employment added")}

  def describe("staff.person_employment_updated"),
    do: {"hero-briefcase", gettext("Employment updated")}

  def describe("staff.person_employment_ended"),
    do: {"hero-briefcase", gettext("Employment ended")}

  def describe("staff.person_employment_removed"),
    do: {"hero-briefcase", gettext("Employment removed")}

  def describe("staff.person_skill_added"), do: {"hero-academic-cap", gettext("Skill added")}

  def describe("staff.person_skill_updated"),
    do: {"hero-academic-cap", gettext("Skill level changed")}

  def describe("staff.person_skill_removed"), do: {"hero-academic-cap", gettext("Skill removed")}

  def describe("staff.person_file_added"), do: {"hero-document-plus", gettext("File(s) added")}
  def describe("staff.person_file_removed"), do: {"hero-document-minus", gettext("File removed")}
  def describe("staff.person_image_added"), do: {"hero-photo", gettext("Image(s) added")}
  def describe("staff.person_image_removed"), do: {"hero-photo", gettext("Image removed")}

  def describe("staff.team_person_added"), do: {"hero-user-group", gettext("Added to a team")}

  def describe("staff.team_person_removed"),
    do: {"hero-user-group", gettext("Removed from a team")}

  def describe(action) when is_binary(action), do: {"hero-clock", humanize(action)}
  def describe(_), do: {"hero-clock", gettext("Activity")}

  # "staff.person_file_added" -> "Person file added"
  defp humanize(action) do
    action
    |> String.split(".")
    |> List.last()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
