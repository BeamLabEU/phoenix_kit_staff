defmodule PhoenixKitStaff.Web.PeopleLive do
  @moduledoc "List staff, with soft-delete (trash / restore / permanent delete) + bulk actions."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, Paths, Staff}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Person
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_people())

    {:ok,
     socket
     |> assign(
       page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "Staff"),
       search: "",
       status: "",
       captured_uuids: [],
       show_bulk_delete_modal: false
     )
     |> load_people()}
  end

  @impl true
  def handle_info({:staff, _event, _payload}, socket), do: {:noreply, load_people(socket)}

  def handle_info(msg, socket) do
    Logger.debug("[Staff] PeopleLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_people(socket) do
    assign(socket,
      people:
        Staff.list_people(
          search: socket.assigns.search,
          status: socket.assigns.status
        ),
      trashed_count: Staff.count_trashed()
    )
  end

  # ── Filtering ──────────────────────────────────────────────────────

  @impl true
  def handle_event("filter", %{"search" => s, "status" => st}, socket) do
    {:noreply, socket |> assign(search: s, status: st) |> load_people()}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, socket |> assign(search: "", status: "") |> load_people()}
  end

  # ── Single-row soft-delete actions ─────────────────────────────────

  def handle_event("trash", %{"uuid" => uuid}, socket), do: with_person(socket, uuid, &do_trash/2)

  def handle_event("restore", %{"uuid" => uuid}, socket),
    do: with_person(socket, uuid, &do_restore/2)

  def handle_event("permanent_delete", %{"uuid" => uuid}, socket),
    do: with_person(socket, uuid, &do_permanent_delete/2)

  # ── Bulk actions (uuids captured client-side by BulkSelectScope) ───

  def handle_event("bulk_trash", %{"uuids" => uuids}, socket) do
    {:ok, count} = Staff.bulk_trash(sanitize_uuids(uuids))

    Activity.log("staff.people_bulk_trashed",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "staff_person",
      metadata: %{"count" => count}
    )

    {:noreply,
     socket
     |> put_flash(
       :info,
       ngettext("Moved 1 staff to trash.", "Moved %{count} staff to trash.", count)
     )
     |> load_people()}
  end

  def handle_event("bulk_restore", %{"uuids" => uuids}, socket) do
    {:ok, count} = Staff.bulk_restore(sanitize_uuids(uuids))

    Activity.log("staff.people_bulk_restored",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "staff_person",
      metadata: %{"count" => count}
    )

    {:noreply,
     socket
     |> put_flash(:info, ngettext("Restored 1 staff.", "Restored %{count} staff.", count))
     |> load_people()}
  end

  # The bulk-select hook can't carry a data-confirm, so a permanent bulk
  # delete first captures the selection + opens a confirm modal; the
  # modal's confirm button fires `bulk_permanent_delete`.
  def handle_event("request_bulk_delete", %{"uuids" => uuids}, socket) do
    {:noreply,
     assign(socket, captured_uuids: sanitize_uuids(uuids), show_bulk_delete_modal: true)}
  end

  def handle_event("cancel_bulk_delete", _params, socket) do
    {:noreply, assign(socket, show_bulk_delete_modal: false, captured_uuids: [])}
  end

  def handle_event("bulk_permanent_delete", _params, socket) do
    uuids = socket.assigns.captured_uuids
    socket = assign(socket, show_bulk_delete_modal: false, captured_uuids: [])

    case Staff.bulk_delete(uuids) do
      {:ok, count} ->
        Activity.log("staff.people_bulk_deleted",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          metadata: %{"count" => count}
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext("Permanently deleted 1 staff.", "Permanently deleted %{count} staff.", count)
         )
         |> load_people()}

      {:error, :referenced_by_external} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Some staff are still referenced elsewhere and couldn't be deleted.")
         )}
    end
  end

  # ── Action helpers ─────────────────────────────────────────────────

  defp with_person(socket, uuid, fun) do
    case Staff.get_person(uuid) do
      nil -> {:noreply, put_flash(socket, :error, gettext("Staff not found."))}
      person -> {:noreply, fun.(socket, person)}
    end
  end

  defp do_trash(socket, person) do
    case Staff.trash_person(person) do
      {:ok, _} ->
        Activity.log("staff.person_trashed",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid,
          metadata: %{}
        )

        socket |> put_flash(:info, gettext("Staff moved to trash.")) |> load_people()

      {:error, :already_trashed} ->
        put_flash(socket, :error, gettext("This staff is already in the trash."))

      {:error, reason} ->
        Helpers.log_operation_error("staff.person_trashed", socket,
          reason: reason,
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid
        )

        put_flash(socket, :error, gettext("Could not move staff to trash."))
    end
  end

  defp do_restore(socket, person) do
    case Staff.restore_person(person) do
      {:ok, _} ->
        Activity.log("staff.person_restored",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid,
          metadata: %{}
        )

        socket |> put_flash(:info, gettext("Staff restored.")) |> load_people()

      {:error, :not_trashed} ->
        put_flash(socket, :error, gettext("This staff isn't in the trash."))

      {:error, reason} ->
        Helpers.log_operation_error("staff.person_restored", socket,
          reason: reason,
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid
        )

        put_flash(socket, :error, gettext("Could not restore staff."))
    end
  end

  defp do_permanent_delete(socket, person) do
    case Staff.delete_person(person) do
      {:ok, _} ->
        Activity.log("staff.person_deleted",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid,
          metadata: %{}
        )

        socket |> put_flash(:info, gettext("Staff permanently deleted.")) |> load_people()

      {:error, :referenced_by_external} ->
        put_flash(
          socket,
          :error,
          gettext("This staff is still referenced elsewhere and couldn't be deleted.")
        )

      {:error, reason} ->
        Helpers.log_operation_error("staff.person_deleted", socket,
          reason: reason,
          resource_type: "staff_person",
          resource_uuid: person.uuid,
          target_uuid: person.user_uuid
        )

        put_flash(socket, :error, gettext("Could not delete staff."))
    end
  end

  defp sanitize_uuids(uuids) when is_list(uuids), do: Enum.filter(uuids, &is_binary/1)
  defp sanitize_uuids(_), do: []

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, viewing_trash: assigns.status == Person.soft_delete_status())

    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <.admin_page_header
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")}
        subtitle={gettext("Everyone on staff, linked to their PhoenixKit user.")}
      >
        <:actions>
          <.link navigate={Paths.new_person()} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New staff")}
          </.link>
        </:actions>
      </.admin_page_header>

      <div class="bg-base-200 rounded-lg p-3">
        <.form for={%{}} phx-change="filter" class="flex flex-wrap gap-3 items-end">
          <.input
            name="search"
            label={Gettext.gettext(PhoenixKitWeb.Gettext, "Search")}
            type="search"
            value={@search}
            placeholder={gettext("search by name or email")}
          />
          <.select
            name="status"
            label={Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}
            value={@status}
            options={[
              {Gettext.gettext(PhoenixKitWeb.Gettext, "All"), ""},
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Active"), "active"},
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Inactive"), "inactive"},
              {trash_option_label(@trashed_count), "trashed"}
            ]}
          />
          <button type="button" phx-click="clear" class="btn btn-ghost btn-sm">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Clear")}
          </button>
        </.form>
      </div>

      <%= if @people == [] do %>
        <.empty_state
          icon="hero-identification"
          title={if @viewing_trash, do: gettext("Trash is empty."), else: gettext("No staff match.")}
        />
      <% else %>
        <.bulk_select_scope
          id="people-bulk"
          total_count={length(@people)}
          class="card bg-base-100 shadow"
        >
          <%!-- Bulk action bar — shown only when rows are selected. --%>
          <div
            class="flex items-center gap-2 px-4 pt-3 flex-wrap"
            data-bulk-show="has-selection"
          >
            <span class="text-sm text-base-content/70">
              <span data-bulk-count>0</span> {gettext("selected")}
            </span>
            <%= if @viewing_trash do %>
              <button type="button" data-bulk-action="bulk_restore" class="btn btn-success btn-xs">
                <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Restore")}
              </button>
              <button
                type="button"
                data-bulk-action="request_bulk_delete"
                class="btn btn-error btn-xs"
              >
                <.icon name="hero-x-circle" class="w-4 h-4" /> {gettext("Delete permanently")}
              </button>
            <% else %>
              <button type="button" data-bulk-action="bulk_trash" class="btn btn-error btn-xs">
                <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Move to trash")}
              </button>
            <% end %>
            <button type="button" data-bulk-clear class="btn btn-ghost btn-xs">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Clear")}
            </button>
          </div>

          <.table_default id="people-list" size="sm">
            <.table_default_header>
              <.table_default_row>
                <.bulk_select_header_cell
                  id="people-select-all"
                  aria_label={gettext("Select all staff")}
                />
                <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</.table_default_header_cell>
                <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Title")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Primary dept")}</.table_default_header_cell>
                <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</.table_default_header_cell>
                <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>
            <tbody>
              <.table_default_row :for={p <- @people}>
                <.bulk_select_cell value={p.uuid} />
                <.table_default_cell>
                  <.link navigate={Paths.person(p.uuid)} class="link link-hover font-medium">
                    {Person.display_name(p)}
                  </.link>
                  <div :if={p.user && p.user.email} class="text-xs text-base-content/50 font-mono">
                    {p.user.email}
                  </div>
                </.table_default_cell>
                <.table_default_cell class="text-sm">{p.job_title || "—"}</.table_default_cell>
                <.table_default_cell>{(p.primary_department && p.primary_department.name) || "—"}</.table_default_cell>
                <.table_default_cell>
                  <span class={"badge badge-sm #{status_badge_class(p.status)}"}>
                    {Person.status_label(p.status)}
                  </span>
                </.table_default_cell>
                <.table_default_cell class="text-right whitespace-nowrap">
                  <.table_row_menu id={"person-menu-#{p.uuid}"}>
                    <%= if Person.trashed?(p) do %>
                      <.table_row_menu_button
                        phx-click="restore"
                        phx-value-uuid={p.uuid}
                        phx-disable-with={gettext("Restoring…")}
                        icon="hero-arrow-uturn-left"
                        label={gettext("Restore")}
                        variant="success"
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="permanent_delete"
                        phx-value-uuid={p.uuid}
                        phx-disable-with={gettext("Deleting…")}
                        data-confirm={gettext("Permanently delete this staff? This cannot be undone and will clear their project-assignment links.")}
                        icon="hero-x-circle"
                        label={gettext("Delete permanently")}
                        variant="error"
                      />
                    <% else %>
                      <.table_row_menu_link
                        navigate={Paths.person(p.uuid)}
                        icon="hero-eye"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                      />
                      <.table_row_menu_link
                        navigate={Paths.edit_person(p.uuid)}
                        icon="hero-pencil"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                        variant="secondary"
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="trash"
                        phx-value-uuid={p.uuid}
                        phx-disable-with={gettext("Moving…")}
                        data-confirm={gettext("Move this staff to the trash? The user account stays; restore anytime from the Trash filter.")}
                        icon="hero-trash"
                        label={gettext("Move to trash")}
                        variant="error"
                      />
                    <% end %>
                  </.table_row_menu>
                </.table_default_cell>
              </.table_default_row>
            </tbody>
          </.table_default>
        </.bulk_select_scope>
      <% end %>

      <.confirm_modal
        :if={@show_bulk_delete_modal}
        show={@show_bulk_delete_modal}
        on_confirm="bulk_permanent_delete"
        on_cancel="cancel_bulk_delete"
        danger
        title={gettext("Delete permanently")}
        confirm_text={gettext("Delete permanently")}
        prompt={
          ngettext(
            "Permanently delete 1 staff? This cannot be undone and will clear their project-assignment links.",
            "Permanently delete %{count} staff? This cannot be undone and will clear their project-assignment links.",
            length(@captured_uuids)
          )
        }
      />
    </div>
    """
  end

  defp trash_option_label(0), do: gettext("Trashed")
  defp trash_option_label(count), do: gettext("Trashed (%{count})", count: count)

  defp status_badge_class("active"), do: "badge-success"
  defp status_badge_class("inactive"), do: "badge-ghost"
  defp status_badge_class("trashed"), do: "badge-error badge-outline"
  defp status_badge_class(_), do: "badge-ghost"
end
