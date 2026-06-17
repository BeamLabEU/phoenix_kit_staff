defmodule PhoenixKitStaff.Web.MultilangDisplayTest do
  @moduledoc """
  Pins the multilang *display* wiring on the read LVs: department / team /
  person free-text fields render the active content-locale override (via the
  schema `localized_*/2` helpers + `L10n.current_content_lang/0`), falling
  back to the primary column when no override exists for the locale.

  Regression guard: PR #8 added this wiring and the 0.5.0 reshape silently
  dropped it (the per-language overrides went write-only). A revert of the
  `localized_*` call sites would re-render the primary value and fail these.

  Locale is set with `Gettext.put_locale/2` in the test process; the
  disconnected render `live/2` returns runs in that process, so
  `current_content_lang/0` (which reads `Gettext.get_locale/1`) sees it.
  """
  use PhoenixKitStaff.LiveCase, async: false

  # The test router only mounts the "en" locale scope, and `Paths.*`
  # prepends the *current* locale — so navigate with literal "/en/..." URLs
  # (URL locale) while `put_locale("et")` drives the *content* locale the
  # render reads via `current_content_lang/0`. The two are independent here.
  @departments_url "/en/admin/staff/departments"
  @skills_url "/en/admin/staff/skills"

  setup %{conn: conn} do
    # The hook puts the locale on the (test) process during the disconnected
    # render, so reset it after each test to avoid leaking into others.
    on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, "en") end)
    conn = conn |> put_test_scope(fake_scope()) |> put_test_locale("et")
    {:ok, conn: conn}
  end

  test "departments list renders the locale override, not the primary name", %{conn: conn} do
    fixture_department(%{
      "name" => "EngineeringPRIMARY",
      "translations" => %{"et" => %{"name" => "InseneriosakondET"}}
    })

    {:ok, _view, html} = live(conn, @departments_url)

    assert html =~ "InseneriosakondET"
    refute html =~ "EngineeringPRIMARY"
  end

  test "person show renders the locale job_title override", %{conn: conn} do
    person =
      fixture_person(%{
        "job_title" => "EngineerPRIMARY",
        "translations" => %{"et" => %{"job_title" => "InsenerET"}}
      })

    {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

    assert html =~ "InsenerET"
    refute html =~ "EngineerPRIMARY"
  end

  test "falls back to the primary value when the locale has no override", %{conn: conn} do
    fixture_department(%{"name" => "NoOverrideDept", "translations" => %{}})

    {:ok, _view, html} = live(conn, @departments_url)

    assert html =~ "NoOverrideDept"
  end

  test "skills list renders the locale name override, not the primary name", %{conn: conn} do
    fixture_skill(%{
      "name" => "ElixirPRIMARY",
      "translations" => %{"et" => %{"name" => "ElixirET"}}
    })

    {:ok, _view, html} = live(conn, @skills_url)

    assert html =~ "ElixirET"
    refute html =~ "ElixirPRIMARY"
  end

  test "skill show renders the locale name + description override", %{conn: conn} do
    skill =
      fixture_skill(%{
        "name" => "ElixirPRIMARY",
        "description" => "DescPRIMARY",
        "translations" => %{"et" => %{"name" => "ElixirET", "description" => "DescET"}}
      })

    {:ok, _view, html} = live(conn, "#{@skills_url}/#{skill.uuid}")

    assert html =~ "ElixirET"
    assert html =~ "DescET"
    refute html =~ "ElixirPRIMARY"
    refute html =~ "DescPRIMARY"
  end
end
