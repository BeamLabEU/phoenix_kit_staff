defmodule PhoenixKitStaff.Web.Components.TabsStrip do
  @moduledoc """
  daisyUI boxed tab switcher for staff detail pages.

  Stateless: the host LiveView owns the active-tab assign and handles
  `@event` (dispatched with a `%{"tab" => value}` payload — keyed `tab`,
  not `value`, to avoid colliding with a `<button>`'s own empty `.value`
  DOM property). Tabs are `{value, label, icon}` tuples; `icon` may be
  `nil`.

      <.tabs_strip
        event="switch_tab"
        active={@active_tab}
        tabs={[
          {"overview", gettext("Overview"), "hero-identification"},
          {"comments", gettext("Comments"), "hero-chat-bubble-left-right"}
        ]}
      />

  …and the host handles `handle_event("switch_tab", %{"tab" => tab}, …)`.

  Mirrors `phoenix_kit_projects`' `TabsStrip` — a candidate for promotion
  to core `PhoenixKitWeb.Components.*` once a third module needs it.
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  attr(:event, :string, required: true)
  attr(:active, :string, required: true)
  attr(:tabs, :list, required: true, doc: "list of {value, label, icon} tuples")
  attr(:class, :string, default: nil)

  def tabs_strip(assigns) do
    ~H"""
    <div role="tablist" class={["tabs tabs-box", @class]}>
      <button
        :for={{value, label, icon} <- @tabs}
        type="button"
        role="tab"
        phx-click={@event}
        phx-value-tab={value}
        class={["tab gap-2", @active == value && "tab-active"]}
      >
        <.icon :if={icon} name={icon} class="w-4 h-4" /> {label}
      </button>
    </div>
    """
  end
end
