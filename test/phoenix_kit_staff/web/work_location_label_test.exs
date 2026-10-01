defmodule PhoenixKitStaff.Web.WorkLocationLabelTest do
  @moduledoc """
  The employment form stores a work location's uuid (picked from the
  Locations module); the profile printed it raw. It shows the location's
  name, and anything it cannot resolve as stored.
  """
  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.Web.Helpers

  test "nothing, free text and an unknown uuid show as stored" do
    assert Helpers.work_location_label(nil) == nil
    assert Helpers.work_location_label("Tallinn office") == "Tallinn office"

    gone = Ecto.UUID.generate()
    assert Helpers.work_location_label(gone) == gone
  end
end
