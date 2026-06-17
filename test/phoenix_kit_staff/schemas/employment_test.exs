defmodule PhoenixKitStaff.Schemas.EmploymentTest do
  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.Schemas.Employment

  defp valid_attrs(extra \\ %{}) do
    Map.merge(%{"staff_person_uuid" => Ecto.UUID.generate()}, extra)
  end

  describe "changeset/2" do
    test "requires staff_person_uuid" do
      cs = Employment.changeset(%Employment{}, %{})
      refute cs.valid?
      assert :staff_person_uuid in Keyword.keys(cs.errors)
    end

    test "accepts a minimal valid span" do
      assert Employment.changeset(%Employment{}, valid_attrs()).valid?
    end

    test "accepts a full valid span" do
      attrs =
        valid_attrs(%{
          "employment_type" => "full_time",
          "job_title" => "Senior Engineer",
          "employment_start_date" => "2021-01-01",
          "employment_end_date" => "2023-06-30",
          "notes" => "Promoted from Junior."
        })

      assert Employment.changeset(%Employment{}, attrs).valid?
    end

    test "rejects an unknown employment_type" do
      cs = Employment.changeset(%Employment{}, valid_attrs(%{"employment_type" => "bogus"}))
      refute cs.valid?
      assert :employment_type in Keyword.keys(cs.errors)
    end

    test "allows a nil/blank employment_type (optional)" do
      assert Employment.changeset(%Employment{}, valid_attrs(%{"employment_type" => ""})).valid?
    end

    test "rejects an end date before the start date" do
      attrs =
        valid_attrs(%{
          "employment_start_date" => "2022-01-01",
          "employment_end_date" => "2021-01-01"
        })

      cs = Employment.changeset(%Employment{}, attrs)
      refute cs.valid?
      assert :employment_end_date in Keyword.keys(cs.errors)
    end

    test "accepts an end date on/after the start date" do
      attrs =
        valid_attrs(%{
          "employment_start_date" => "2021-01-01",
          "employment_end_date" => "2021-01-01"
        })

      assert Employment.changeset(%Employment{}, attrs).valid?
    end

    test "rejects a malformed translations shape" do
      cs =
        Employment.changeset(%Employment{}, valid_attrs(%{"translations" => %{"et" => "nope"}}))

      refute cs.valid?
    end
  end

  describe "helpers" do
    test "open?/1 is true only with no end date" do
      assert Employment.open?(%Employment{employment_end_date: nil})
      refute Employment.open?(%Employment{employment_end_date: ~D[2020-01-01]})
    end

    test "localized_job_title/2 uses the override, falls back to primary" do
      e = %Employment{job_title: "Engineer", translations: %{"et" => %{"job_title" => "Insener"}}}
      assert Employment.localized_job_title(e, "et") == "Insener"
      assert Employment.localized_job_title(e, "ru") == "Engineer"
    end
  end
end
