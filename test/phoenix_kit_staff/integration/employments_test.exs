defmodule PhoenixKitStaff.Integration.EmploymentsTest do
  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKitStaff.Employments
  alias PhoenixKitStaff.Schemas.Person

  defp reload(uuid), do: PhoenixKit.RepoHelper.repo().get(Person, uuid)

  defp open_count(uuid),
    do: Enum.count(Employments.list_for_person(uuid), &(&1.employment_end_date == nil))

  describe "create/2 + sync_current denormalization" do
    test "an open span mirrors onto Person" do
      p = fixture_person()

      {:ok, _span} =
        Employments.create(p.uuid, %{
          "employment_type" => "full_time",
          "job_title" => "Dev",
          "employment_start_date" => "2021-01-01"
        })

      person = reload(p.uuid)
      assert person.employment_type == "full_time"
      assert person.job_title == "Dev"
      assert person.employment_start_date == ~D[2021-01-01]
      assert person.employment_end_date == nil
    end

    test "the span's department syncs to Person.primary_department_uuid" do
      p = fixture_person()
      dept = fixture_department()

      {:ok, _} =
        Employments.create(p.uuid, %{"primary_department_uuid" => dept.uuid, "job_title" => "Dev"})

      assert reload(p.uuid).primary_department_uuid == dept.uuid
    end

    test "job_title translations mirror onto Person without clobbering bio" do
      p = fixture_person(%{"bio" => "hi", "translations" => %{"et" => %{"bio" => "tere"}}})

      {:ok, _} =
        Employments.create(p.uuid, %{
          "job_title" => "Dev",
          "translations" => %{"et" => %{"job_title" => "Arendaja"}}
        })

      person = reload(p.uuid)
      assert person.translations["et"]["job_title"] == "Arendaja"
      assert person.translations["et"]["bio"] == "tere"
    end
  end

  describe "one-open-span invariant" do
    test "starting a new open span closes the prior open one at the new start" do
      p = fixture_person()

      {:ok, first} =
        Employments.create(p.uuid, %{
          "job_title" => "Junior",
          "employment_start_date" => "2020-01-01"
        })

      assert first.employment_end_date == nil

      {:ok, second} =
        Employments.create(p.uuid, %{
          "job_title" => "Senior",
          "employment_start_date" => "2022-01-01"
        })

      assert second.employment_end_date == nil
      assert Employments.get(first.uuid).employment_end_date == ~D[2022-01-01]
      assert open_count(p.uuid) == 1
      # Person mirrors the current (Senior) span.
      assert reload(p.uuid).job_title == "Senior"
    end

    test "adding a closed (historical) span does not touch the open one" do
      p = fixture_person()
      {:ok, current} = Employments.create(p.uuid, %{"job_title" => "Current"})

      {:ok, _past} =
        Employments.create(p.uuid, %{
          "job_title" => "Past",
          "employment_start_date" => "2015-01-01",
          "employment_end_date" => "2016-01-01"
        })

      assert Employments.get(current.uuid).employment_end_date == nil
      assert open_count(p.uuid) == 1
    end
  end

  describe "end_span/2 and delete/1" do
    test "ending the open span sets its end date and mirrors onto Person" do
      p = fixture_person()

      {:ok, span} =
        Employments.create(p.uuid, %{
          "job_title" => "Dev",
          "employment_start_date" => "2020-01-01"
        })

      {:ok, _} = Employments.end_span(span, ~D[2023-01-01])

      assert reload(p.uuid).employment_end_date == ~D[2023-01-01]
      assert open_count(p.uuid) == 0
    end

    test "deleting the last span clears the Person mirror" do
      p = fixture_person()

      {:ok, span} =
        Employments.create(p.uuid, %{"employment_type" => "full_time", "job_title" => "Dev"})

      {:ok, _} = Employments.delete(span)

      person = reload(p.uuid)
      assert person.job_title == nil
      assert person.employment_type == nil
      assert person.primary_department_uuid == nil
      assert Employments.list_for_person(p.uuid) == []
    end

    test "deleting a closed span re-syncs from the remaining open span" do
      p = fixture_person()
      {:ok, current} = Employments.create(p.uuid, %{"job_title" => "Current"})

      {:ok, past} =
        Employments.create(p.uuid, %{
          "job_title" => "Past",
          "employment_start_date" => "2015-01-01",
          "employment_end_date" => "2016-01-01"
        })

      {:ok, _} = Employments.delete(past)

      assert reload(p.uuid).job_title == "Current"
      assert [%{uuid: uuid}] = Employments.list_for_person(p.uuid)
      assert uuid == current.uuid
    end
  end

  describe "list_for_person/1 ordering" do
    test "the open span comes first, then closed spans newest-first" do
      p = fixture_person()

      {:ok, _old} =
        Employments.create(p.uuid, %{
          "job_title" => "Old",
          "employment_start_date" => "2018-01-01",
          "employment_end_date" => "2019-01-01"
        })

      {:ok, _current} =
        Employments.create(p.uuid, %{
          "job_title" => "Current",
          "employment_start_date" => "2020-01-01"
        })

      assert [first | _] = Employments.list_for_person(p.uuid)
      assert first.job_title == "Current"
      assert first.employment_end_date == nil
    end
  end
end
