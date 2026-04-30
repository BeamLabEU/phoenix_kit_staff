defmodule PhoenixKitStaff.Web.SubscribeBeforeFetchTest do
  @moduledoc """
  Pins the Batch 2 PubSub-race fix: the three show LVs must subscribe
  to their per-record topic BEFORE running the DB read. If subscribe
  comes after the fetch, a broadcast fired in the gap goes to nobody.

  The race window is microseconds; we can't reliably trigger it from
  tests. Instead we structurally pin the order via a source-pairing
  meta-test — the 3 mount blocks must contain `subscribe(` before
  `Departments.get(`, `Teams.get(`, or `Staff.get_person(` respectively.
  Same shape as the publishing-Batch-2 phx-disable-with paired test.
  """

  use ExUnit.Case, async: true

  @show_pages [
    {"department_show_live.ex", "Departments.get(", "topic_department"},
    {"team_show_live.ex", "Teams.get(", "topic_team"},
    {"person_show_live.ex", "Staff.get_person(", "topic_person"}
  ]

  for {file, fetch_call, topic_helper} <- @show_pages do
    test "#{file} subscribes via #{topic_helper} BEFORE the DB fetch via #{fetch_call}" do
      path =
        Path.join([
          File.cwd!(),
          "lib",
          "phoenix_kit_staff",
          "web",
          unquote(file)
        ])

      source = File.read!(path)

      # Find the subscribe and fetch lines inside the mount/3 function
      # body (pre-`case`-tail-clause).
      mount_block =
        Regex.run(~r/def mount.*?\n\s*end\b/s, source)
        |> case do
          [m] -> m
          _ -> flunk("Could not isolate mount/3 block in #{unquote(file)}")
        end

      subscribe_idx =
        :binary.match(mount_block, "subscribe(") |> elem(0)

      fetch_idx =
        :binary.match(mount_block, unquote(fetch_call)) |> elem(0)

      assert subscribe_idx < fetch_idx,
             """
             Expected #{unquote(file)} mount/3 to call subscribe(...) BEFORE
             #{unquote(fetch_call)}.

             Got:
               subscribe at offset #{subscribe_idx}
               #{unquote(fetch_call)} at offset #{fetch_idx}

             A broadcast firing between fetch and subscribe is silently dropped
             — the receiving LV stays stale until the next manual reload.
             """
    end
  end
end
