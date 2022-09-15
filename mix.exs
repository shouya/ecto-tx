defmodule Tx.MixProject do
  use Mix.Project

  def project do
    [
      app: :tx,
      description: "A composable database transaction library",
      version: "0.1.2",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, ">= 0.0.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "tx",
      files: ~w(lib mix.exs README.md LICENSE),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/shouya/ecto-tx"}
    ]
  end
end
