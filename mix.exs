defmodule PhoenixGenApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :phoenix_gen_api,
      version: "0.0.7",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Docs
      name: "PhoenixGenApi",
      source_url: "https://github.com/ohhi-vn/phoenix_gen_api",
      homepage_url: "https://ohhi.vn",
      docs: docs(),
      description: description(),
      package: package()
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
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.24", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev},
    ]

  end

  defp package() do
    [
      maintainers: ["Manh Van Vu"],
      licenses: ["MPL-2.0"],
      links: %{"GitHub" => "https://github.com/ohhi-vn/phoenix_gen_api", "About us" => "https://ohhi.vn/"}
    ]
  end

  defp description() do
    "A library to add dynamic API to Phoenix Channels, with the ability to pull config from remote nodes. Easy to use, easy to extend & scale."
  end

  defp docs do
    [
      main: "readme",
      extras: extras()
    ]
  end

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
          "F A Q" ->"FAQ"
          no_change -> no_change
        end

      {String.to_atom(path),
        [
          title: title,
          default: title == "Guide"
        ]
      }
    end)

  end
end
