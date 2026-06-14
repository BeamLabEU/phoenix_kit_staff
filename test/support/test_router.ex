defmodule PhoenixKitStaff.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitStaff.Paths` so `live/2` calls in tests work
  with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  phoenix_kit_settings table is unavailable, and admin paths always get
  the default locale ("en") prefix — so our base becomes
  `/en/admin/staff`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitStaff.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/staff", PhoenixKitStaff.Web do
    pipe_through(:browser)

    live_session :staff_test,
      layout: {PhoenixKitStaff.Test.Layouts, :app},
      on_mount: {PhoenixKitStaff.Test.Hooks, :assign_scope} do
      live("/", OverviewLive, :index)

      live("/departments", DepartmentsLive, :index)
      live("/departments/new", DepartmentFormLive, :new)
      live("/departments/:id", DepartmentShowLive, :show)
      live("/departments/:id/edit", DepartmentFormLive, :edit)

      live("/teams", TeamsLive, :index)
      live("/teams/new", TeamFormLive, :new)
      live("/teams/:id", TeamShowLive, :show)
      live("/teams/:id/edit", TeamFormLive, :edit)

      live("/people", PeopleLive, :index)
      live("/people/new", PersonFormLive, :new)
      live("/people/:id", PersonShowLive, :show)
      live("/people/:id/edit", PersonFormLive, :edit)

      live("/skills", SkillsLive, :index)
      live("/skills/new", SkillFormLive, :new)
      live("/skills/:id", SkillShowLive, :show)
      live("/skills/:id/edit", SkillFormLive, :edit)
    end
  end
end
