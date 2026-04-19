defmodule PhoenixKitStaff.PubSubTest do
  use ExUnit.Case, async: true

  alias PhoenixKitStaff.PubSub, as: P

  describe "topics" do
    test "all top-level topics are stable strings" do
      assert P.topic_departments() == "staff:departments"
      assert P.topic_teams() == "staff:teams"
      assert P.topic_people() == "staff:people"
    end

    test "per-resource topics embed the uuid" do
      assert P.topic_department("d1") == "staff:department:d1"
      assert P.topic_team("t1") == "staff:team:t1"
      assert P.topic_person("p1") == "staff:person:p1"
    end
  end
end
