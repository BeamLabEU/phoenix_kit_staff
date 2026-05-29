defmodule PhoenixKitStaff.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_staff"

  def project do
    [
      app: :phoenix_kit_staff,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_ignore_filters: [~r"/support/"],
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitStaff\.Test\./,
          PhoenixKitStaff.DataCase,
          PhoenixKitStaff.LiveCase,
          PhoenixKitStaff.ActivityLogAssertions
        ]
      ],
      description: "Staff module for PhoenixKit — departments, teams, and people.",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitStaff",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :phoenix_kit]]
  end

  def cli do
    [preferred_envs: ["test.setup": :test, "test.reset": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitStaff.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitStaff.Test.Repo",
        "test.setup"
      ]
    ]
  end

  defp deps do
    [
      {:phoenix_kit, "~> 1.7.125"},
      {:phoenix_live_view, "~> 1.1"},
      {:ecto_sql, "~> 3.13"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # `Phoenix.LiveViewTest` parses HTML via `lazy_html` for `element/2`,
      # `render(view) =~ "..."`, etc. Test-only.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [main: "PhoenixKitStaff", source_ref: "v#{@version}"]
  end
end
