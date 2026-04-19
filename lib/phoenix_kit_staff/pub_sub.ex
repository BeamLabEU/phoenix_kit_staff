defmodule PhoenixKitStaff.PubSub do
  @moduledoc """
  Real-time updates for the staff module, backed by
  `PhoenixKit.PubSub.Manager` (the shared in-process PubSub server).

  ## Topics

    * `"staff:departments"` — any department mutation
    * `"staff:teams"` — any team mutation
    * `"staff:people"` — any person mutation
    * `"staff:department:<uuid>"` — a single department
    * `"staff:team:<uuid>"` — a single team
    * `"staff:person:<uuid>"` — a single person

  ## Events

  Messages are `{:staff, event_atom, payload_map}` tuples. Payload always
  includes `:uuid` at a minimum. Subscribers should pattern-match on the
  event atom in `handle_info/2`.
  """

  alias PhoenixKit.PubSub.Manager

  # ── Topics ─────────────────────────────────────────────────────────

  @doc "Topic for all department mutations."
  def topic_departments, do: "staff:departments"
  @doc "Topic for all team mutations."
  def topic_teams, do: "staff:teams"
  @doc "Topic for all person mutations."
  def topic_people, do: "staff:people"
  @doc "Topic scoped to a single department."
  def topic_department(uuid), do: "staff:department:#{uuid}"
  @doc "Topic scoped to a single team."
  def topic_team(uuid), do: "staff:team:#{uuid}"
  @doc "Topic scoped to a single person."
  def topic_person(uuid), do: "staff:person:#{uuid}"

  # ── Subscribe ──────────────────────────────────────────────────────

  @doc "Subscribes the calling process to the given PubSub topic."
  def subscribe(topic), do: Manager.subscribe(topic)

  # ── Broadcast ──────────────────────────────────────────────────────

  @doc "Broadcasts a department event to the departments topic and the department's own topic."
  def broadcast_department(event, %{uuid: uuid} = payload) do
    msg = {:staff, event, payload}
    Manager.broadcast(topic_departments(), msg)
    Manager.broadcast(topic_department(uuid), msg)
  end

  @doc "Broadcasts a team event to the teams, team, and (if present) parent-department topics."
  def broadcast_team(event, %{uuid: uuid} = payload) do
    msg = {:staff, event, payload}
    Manager.broadcast(topic_teams(), msg)
    Manager.broadcast(topic_team(uuid), msg)

    case Map.get(payload, :department_uuid) do
      nil -> :ok
      dept_uuid -> Manager.broadcast(topic_department(dept_uuid), msg)
    end
  end

  @doc "Broadcasts a person event to the people topic and the person's own topic."
  def broadcast_person(event, %{uuid: uuid} = payload) do
    msg = {:staff, event, payload}
    Manager.broadcast(topic_people(), msg)
    Manager.broadcast(topic_person(uuid), msg)
  end

  @doc "Broadcasts a team-membership event to the teams, team, people, and person topics."
  def broadcast_team_membership(
        event,
        %{team_uuid: team_uuid, staff_person_uuid: person_uuid} = payload
      ) do
    msg = {:staff, event, payload}
    Manager.broadcast(topic_teams(), msg)
    Manager.broadcast(topic_team(team_uuid), msg)
    Manager.broadcast(topic_people(), msg)
    Manager.broadcast(topic_person(person_uuid), msg)
  end
end
