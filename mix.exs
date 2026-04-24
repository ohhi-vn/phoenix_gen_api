defmodule PhoenixGenApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_gen_api,
      version: "2.10.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Docs
      name: "PhoenixGenApi",
      source_url: "https://github.com/ohhi-vn/phoenix_gen_api",
      homepage_url: "https://ohhi.vn",
      docs: docs(),
      description: description(),
      package: package(),
      aliases: aliases(),
      usage_rules: usage_rules()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {PhoenixGenApi.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nestru, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:benchee, "~> 1.5", only: :dev},
      {:tidewave, "~> 0.5", only: [:dev]},
      {:usage_rules, "~> 1.2", only: [:dev]}
    ]
  end

  defp package() do
    [
      maintainers: ["Manh Vu"],
      licenses: ["MPL-2.0"],
      links: %{
        "GitHub" => "https://github.com/ohhi-vn/phoenix_gen_api",
        "About us" => "https://ohhi.vn/"
      }
    ]
  end

  defp description() do
    "A library for fast develop APIs in Elixir cluster, using Phoenix Channels for transport data, auto pull api configs from service nodes."
  end

  defp docs do
    [
      main: "readme",
      extras: extras()
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp extras do
    list =
      "guides/**/*.md"
      |> Path.wildcard()

    list = list ++ ["README.md"]

    list
    |> Enum.map(fn path ->
      title =
        path
        |> Path.basename(".md")
        |> String.split(~r|[-_]|)
        |> Enum.map_join(" ", &String.capitalize/1)
        |> case do
          "F A Q" -> "FAQ"
          no_change -> no_change
        end

      {String.to_atom(path),
       [
         title: title,
         default: title == "Guide"
       ]}
    end)
  end

  defp aliases do
    [
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"],
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4114) end)'",
      "usage_rules.update": [
        """
        usage_rules.sync AGENTS.md --all \
          --inline usage_rules:all \
          --link-to-folder deps
        """
        |> String.trim()
      ]
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: :all
    ]
  end
end
