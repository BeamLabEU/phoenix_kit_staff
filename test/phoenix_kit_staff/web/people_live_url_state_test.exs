defmodule PhoenixKitStaff.Web.PeopleLiveUrlStateTest do
  @moduledoc """
  The staff list's URL-backed search and status filter, pinned through the
  codec rather than a live view: the spec is the part that drifts silently,
  and asserting on it needs no database, so this runs even where the
  integration suite is excluded.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitStaff.Schemas.Person
  alias PhoenixKitStaff.Web.PeopleLive
  alias PhoenixKitWeb.Live.UrlState

  defp cfg, do: PeopleLive.__phoenix_kit_url_state__()
  defp spec(key), do: Enum.find(cfg().params, &(&1.key == key))

  describe "declared spec" do
    test "search is published as ?q= and defaults to unfiltered" do
      assert %{url_key: "q", default: "", cast: :string, allowed: nil} = spec(:search)
    end

    test "status whitelist matches the values the form offers and scope_status/3 handles" do
      # Three lists have to agree: this whitelist, the `options` of the status
      # `<.select>` in the render, and `Staff.scope_status/3`. Deriving the
      # whitelist from `Person.statuses/0` would be worse than hardcoding it —
      # a status added there but not taught to `scope_status/3` would reach the
      # URL and then be silently ignored — so the drift is caught here instead.
      assert Enum.sort(spec(:status).allowed) ==
               Enum.sort(["", Person.soft_delete_status() | Person.statuses()])
    end
  end

  describe "decode/2 — reading a shared link" do
    test "a filtered link restores both controls" do
      assert %{search: "ann", status: "inactive"} =
               UrlState.decode(%{"q" => "ann", "status" => "inactive"}, cfg())
    end

    test "a bare path is the unfiltered list" do
      assert %{search: "", status: ""} = UrlState.decode(%{}, cfg())
    end

    test "the trash view is reachable by URL" do
      assert %{status: "trashed"} = UrlState.decode(%{"status" => "trashed"}, cfg())
    end

    test "a status outside the whitelist falls back to unfiltered" do
      # The value is interpolated into `scope_status/3`'s query, so a crafted
      # link must never carry one the whitelist has not vetted.
      for crafted <- ["admin", "' OR 1=1 --", "TRASHED", "deleted"] do
        assert %{status: ""} = UrlState.decode(%{"status" => crafted}, cfg())
      end
    end
  end

  describe "encode/3 — writing the address bar" do
    test "an unfiltered list carries no query string" do
      assert UrlState.encode(%{search: "", status: ""}, cfg()) == %{}
    end

    test "a filtered list is a shareable query" do
      assert UrlState.encode(%{search: "ann", status: "active"}, cfg()) ==
               %{"q" => "ann", "status" => "active"}
    end

    test "an unrelated query key survives a filter change" do
      assert %{"return_to" => "/somewhere"} =
               UrlState.encode(%{search: "", status: ""}, cfg(), %{"return_to" => "/somewhere"})
    end
  end
end
