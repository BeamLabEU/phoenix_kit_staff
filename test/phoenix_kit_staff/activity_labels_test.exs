defmodule PhoenixKitStaff.ActivityLabelsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.ActivityLabels

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
end
