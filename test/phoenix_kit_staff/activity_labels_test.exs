defmodule PhoenixKitStaff.ActivityLabelsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.ActivityLabels
  alias PhoenixKitStaff.Schemas.Person

  test "maps known staff actions to an {icon, label} pair" do
    assert {"hero-briefcase", "Employment added"} =
             ActivityLabels.describe("staff.person_employment_added")

    assert {"hero-trash", "Moved to trash"} = ActivityLabels.describe("staff.person_trashed")
  end

  test "pluralizes the file/image added labels by the metadata count" do
    assert {"hero-photo", "Image added"} =
             ActivityLabels.describe("staff.person_image_added", %{"count" => 1})

    assert {"hero-photo", "Images added"} =
             ActivityLabels.describe("staff.person_image_added", %{"count" => 3})

    assert {"hero-document-plus", "File added"} =
             ActivityLabels.describe("staff.person_file_added", %{"count" => 1})

    assert {"hero-document-plus", "Files added"} =
             ActivityLabels.describe("staff.person_file_added", %{"count" => 2})

    # No/!integer count → singular.
    assert {"hero-photo", "Image added"} = ActivityLabels.describe("staff.person_image_added")
  end

  test "falls back to a humanized label for unknown actions" do
    assert {"hero-clock", "Person did something"} =
             ActivityLabels.describe("staff.person_did_something")
  end

  test "is total — never raises on odd input" do
    assert {"hero-clock", _} = ActivityLabels.describe("")
    assert {"hero-clock", _} = ActivityLabels.describe(nil)
  end

  describe "detail/2" do
    test "surfaces employment type and person status from metadata" do
      assert ActivityLabels.detail("staff.person_employment_added", %{
               "employment_type" => "full_time"
             }) == Person.employment_type_label("full_time")

      assert ActivityLabels.detail("staff.person_employment_ended", %{
               "employment_type" => "contractor"
             }) == Person.employment_type_label("contractor")

      assert ActivityLabels.detail("staff.person_created", %{"status" => "active"}) ==
               Person.status_label("active")
    end

    test "pluralizes file/image/level counts" do
      assert ActivityLabels.detail("staff.person_file_added", %{"count" => 1}) == "1 file"
      assert ActivityLabels.detail("staff.person_file_added", %{"count" => 3}) == "3 files"
      assert ActivityLabels.detail("staff.person_image_added", %{"count" => 2}) == "2 images"

      assert ActivityLabels.detail("staff.person_skill_updated", %{
               "proficiency_levels" => ["a", "b"]
             }) == "2 levels"
    end

    test "returns nil when there's nothing extra to show" do
      assert ActivityLabels.detail("staff.person_updated", %{}) == nil
      assert ActivityLabels.detail("staff.person_trashed", %{}) == nil
      assert ActivityLabels.detail("staff.person_employment_added", %{}) == nil

      assert ActivityLabels.detail("staff.person_skill_added", %{"proficiency_levels" => []}) ==
               nil
    end
  end
end
