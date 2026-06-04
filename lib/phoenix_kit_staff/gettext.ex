defmodule PhoenixKitStaff.Gettext do
  @moduledoc """
  Gettext backend for staff-module-specific UI strings.

  Files in this module that wrap domain strings (staff, person,
  department, team, membership UI) declare
  `use Gettext, backend: PhoenixKitStaff.Gettext` and call `gettext(...)`.
  Translations live in `priv/gettext/` of this repo — `mix gettext.extract`
  + `mix gettext.merge priv/gettext` keep them in sync.

  Generic/common strings shared across the workspace (month names, date
  templates) stay on core's `PhoenixKitWeb.Gettext` backend — see
  `PhoenixKitStaff.L10n`, which keeps using it so those are translated once
  at the workspace level.

  The Phoenix-request pipeline sets the locale globally via
  `Gettext.put_locale/1`, which every backend reads from the process
  dictionary — so a single locale switch in the parent app drives both this
  backend and `PhoenixKitWeb.Gettext`.
  """

  use Gettext.Backend, otp_app: :phoenix_kit_staff
end
