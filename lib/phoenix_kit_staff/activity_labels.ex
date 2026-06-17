defmodule PhoenixKitStaff.ActivityLabels do
  @moduledoc """
  Maps staff activity action strings (e.g. `"staff.person_employment_added"`)
  to a `{heroicon, human_label}` pair for the person profile's **Events** tab.
  Domain labels go through `PhoenixKitStaff.Gettext`. Unknown actions fall back
  to a humanized form of the action string so a newly-added action still renders
  sensibly without a code change here.

  The file/image "added" actions log a `"count"` in their metadata, so
  `describe/2` accepts the entry's metadata and pluralizes those labels.
  """

  use Gettext, backend: PhoenixKitStaff.Gettext

  alias PhoenixKitStaff.Schemas.Person

  @doc "Returns `{icon_name, label}` for an action string + its metadata."
  @spec describe(String.t(), map()) :: {String.t(), String.t()}
  def describe(action, metadata \\ %{})

  def describe("staff.person_created", _meta), do: {"hero-user-plus", gettext("Profile created")}

  def describe("staff.person_updated", _meta),
    do: {"hero-pencil-square", gettext("Profile updated")}

  def describe("staff.person_deleted", _meta),
    do: {"hero-x-circle", gettext("Profile permanently deleted")}

  def describe("staff.person_trashed", _meta), do: {"hero-trash", gettext("Moved to trash")}

  def describe("staff.person_restored", _meta),
    do: {"hero-arrow-uturn-left", gettext("Restored from trash")}

  def describe("staff.person_avatar_set", _meta),
    do: {"hero-user-circle", gettext("Profile photo updated")}

  def describe("staff.person_avatar_removed", _meta),
    do: {"hero-user-circle", gettext("Profile photo removed")}

  def describe("staff.person_employment_added", _meta),
    do: {"hero-briefcase", gettext("Employment added")}

  def describe("staff.person_employment_updated", _meta),
    do: {"hero-briefcase", gettext("Employment updated")}

  def describe("staff.person_employment_ended", _meta),
    do: {"hero-briefcase", gettext("Employment ended")}

  def describe("staff.person_employment_removed", _meta),
    do: {"hero-briefcase", gettext("Employment removed")}

  def describe("staff.person_skill_added", _meta),
    do: {"hero-academic-cap", gettext("Skill added")}

  def describe("staff.person_skill_updated", _meta),
    do: {"hero-academic-cap", gettext("Skill level changed")}

  def describe("staff.person_skill_removed", _meta),
    do: {"hero-academic-cap", gettext("Skill removed")}

  def describe("staff.person_file_added", meta),
    do: {"hero-document-plus", ngettext("File added", "Files added", count_of(meta))}

  def describe("staff.person_file_removed", _meta),
    do: {"hero-document-minus", gettext("File removed")}

  def describe("staff.person_image_added", meta),
    do: {"hero-photo", ngettext("Image added", "Images added", count_of(meta))}

  def describe("staff.person_image_removed", _meta), do: {"hero-photo", gettext("Image removed")}

  def describe("staff.team_person_added", _meta),
    do: {"hero-user-group", gettext("Added to a team")}

  def describe("staff.team_person_removed", _meta),
    do: {"hero-user-group", gettext("Removed from a team")}

  def describe(action, _meta) when is_binary(action), do: {"hero-clock", humanize(action)}
  def describe(_action, _meta), do: {"hero-clock", gettext("Activity")}

  @doc """
  An optional secondary detail string for an event, pulled from its metadata
  (employment type, file/image count, person status, skill-level count), or
  `nil` when there's nothing extra worth showing. Lets the Events feed say
  *what* happened, not just the action category.
  """
  @spec detail(String.t(), map()) :: String.t() | nil
  def detail("staff.person_created", %{"status" => status})
      when is_binary(status) and status != "",
      do: Person.status_label(status)

  def detail("staff.person_employment_" <> _verb, %{"employment_type" => type})
      when is_binary(type) and type != "",
      do: Person.employment_type_label(type)

  def detail("staff.person_file_added", %{"count" => n}) when is_integer(n) and n > 0,
    do: ngettext("%{count} file", "%{count} files", n)

  def detail("staff.person_image_added", %{"count" => n}) when is_integer(n) and n > 0,
    do: ngettext("%{count} image", "%{count} images", n)

  def detail(action, %{"proficiency_levels" => levels})
      when action in ["staff.person_skill_added", "staff.person_skill_updated"] and
             is_list(levels) and levels != [],
      do: ngettext("%{count} level", "%{count} levels", length(levels))

  def detail(_action, _metadata), do: nil

  # Number of files in an "added" batch, from the logged metadata (≥1).
  defp count_of(%{"count" => n}) when is_integer(n) and n > 0, do: n
  defp count_of(_), do: 1

  # "staff.person_file_added" -> "Person file added"
  defp humanize(action) do
    action
    |> String.split(".")
    |> List.last()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
