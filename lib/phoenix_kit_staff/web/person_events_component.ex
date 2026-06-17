defmodule PhoenixKitStaff.Web.PersonEventsComponent do
  @moduledoc """
  The **Events** tab of a staff person's profile — a read-only, paginated feed
  of the activity logged for this person (`PhoenixKit.Activity` entries scoped
  to `resource_type: "staff_person"` + the person's uuid). Staff already logs
  ~all person mutations (create/update/trash/restore, employment, skills, file/
  image add+remove), so this is the person's audit timeline.

  Read-only by design: no live PubSub prepend (a fresh load on tab open / page
  change is enough for an audit log, and avoids the page-vs-prepend hazard).
  Labels/icons come from `PhoenixKitStaff.ActivityLabels`; badge colour reuses
  core `PhoenixKit.Activity.action_badge_color/1`.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger
  import Ecto.Query, warn: false

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKitStaff.{ActivityLabels, L10n}

  @per_page 20

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign_new(:page, fn -> 1 end)
     |> load_events()}
  end

  @impl true
  def handle_event("events_page", %{"page" => page}, socket) do
    page =
      case Integer.parse(to_string(page)) do
        {n, _} when n >= 1 -> n
        _ -> 1
      end

    {:noreply, socket |> assign(:page, page) |> load_events()}
  end

  # Scope the feed to THIS person. NOTE: we query `Activity.Entry` directly
  # rather than `Activity.list/1` because core's `apply_filters/2` honours
  # `resource_type` but not `resource_uuid` — `list/1` would leak every staff
  # person's events into each profile. Direct query keeps pagination correct.
  defp load_events(socket) do
    person_uuid = socket.assigns.person.uuid

    base =
      from(e in Entry,
        where: e.resource_type == "staff_person" and e.resource_uuid == ^person_uuid,
        order_by: [desc: e.inserted_at]
      )

    {entries, total} = fetch_page(base, socket.assigns.page)

    assign(socket,
      events: entries,
      total: total,
      total_pages: max(ceil(total / @per_page), 1)
    )
  end

  defp fetch_page(base, page) do
    repo = PhoenixKit.RepoHelper.repo()
    total = repo.aggregate(base, :count)

    entries =
      base
      |> limit(^@per_page)
      |> offset(^((page - 1) * @per_page))
      |> repo.all()
      |> repo.preload(:actor)

    {entries, total}
  rescue
    error ->
      Logger.warning("[Staff] events load failed: #{inspect(error)}")
      {[], 0}
  end

  defp actor_label(%{actor: %{email: email}}) when is_binary(email), do: email
  defp actor_label(_), do: gettext("System")

  defp format_at(%DateTime{} = dt),
    do: "#{L10n.format_date(dt)} · #{Calendar.strftime(dt, "%H:%M")}"

  defp format_at(other), do: L10n.format_date(other) || ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-clock" class="w-5 h-5" /> {gettext("Events")} ({@total})
        </h2>

        <p :if={@events == []} class="text-sm text-base-content/60 py-2">
          {gettext("No activity recorded for this person yet.")}
        </p>

        <ul :if={@events != []} class="flex flex-col divide-y divide-base-200">
          <li :for={e <- @events} class="flex items-start gap-3 py-2.5">
            <% {icon, label} = ActivityLabels.describe(e.action) %>
            <span class={"badge badge-sm shrink-0 mt-0.5 #{Activity.action_badge_color(e.action)}"}>
              <.icon name={icon} class="w-3.5 h-3.5" />
            </span>
            <div class="flex-1 min-w-0">
              <div class="text-sm font-medium">{label}</div>
              <div class="text-xs text-base-content/50">
                {actor_label(e)} · {format_at(e.inserted_at)}
              </div>
            </div>
          </li>
        </ul>

        <div :if={@total_pages > 1} class="flex items-center justify-between gap-2 pt-3">
          <button
            type="button"
            phx-target={@myself}
            phx-click="events_page"
            phx-value-page={@page - 1}
            disabled={@page <= 1}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-chevron-left" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Previous")}
          </button>
          <span class="text-xs text-base-content/60">
            {gettext("Page %{page} of %{total}", page: @page, total: @total_pages)}
          </span>
          <button
            type="button"
            phx-target={@myself}
            phx-click="events_page"
            phx-value-page={@page + 1}
            disabled={@page >= @total_pages}
            class="btn btn-ghost btn-sm"
          >
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Next")} <.icon name="hero-chevron-right" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end
end
