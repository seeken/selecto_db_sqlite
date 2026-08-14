defmodule Selecto.DB.SQLite.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/selecto/selecto_db_sqlite"

  def project do
    [
      app: :selecto_db_sqlite,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      selecto_dep(),
      {:exqlite, "~> 0.13"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.27", only: :dev, runtime: false}
    ]
  end

  defp selecto_dep do
    if use_local_ecosystem?() do
      {:selecto, path: local_selecto_path()}
    else
      {:selecto, ">= 0.5.0 and < 0.6.0"}
    end
  end

  defp local_selecto_path do
    "SELECTO_ECOSYSTEM_SELECTO_PATH"
    |> System.get_env("../selecto")
    |> Path.expand(__DIR__)
  end

  defp use_local_ecosystem? do
    case System.get_env("SELECTO_ECOSYSTEM_USE_LOCAL") do
      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
      value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
      _ -> File.dir?(Path.expand("../selecto", __DIR__))
    end
  end

  defp description do
    "SQLite adapter for Selecto query builder"
  end

  defp package do
    [
      name: "selecto_db_sqlite",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Selecto" => "https://github.com/selecto/selecto"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
