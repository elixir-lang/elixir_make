defmodule ElixirMake.Mixfile do
  use Mix.Project

  @version "0.6.3"

  def project do
    [
      app: :elixir_make,
      version: @version,
      elixir: "~> 1.3",
      description: "A Make compiler for Mix",
      package: package(),
      docs: docs(),
      deps: deps(),
      make_precompiler: FennecPrecompile.Precompiler
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :inets, :public_key, :fennec_precompile]]
  end

  defp deps do
    [
      {:castore, "~> 0.1", runtime: false},
      {:fennec_precompile, "~> 0.2", runtime: false},
      {:ex_doc, "~> 0.20", only: :docs}
    ]
  end

  defp package do
    %{
      licenses: ["Apache 2"],
      links: %{"GitHub" => "https://github.com/elixir-lang/elixir_make"},
      maintainers: ["Andrea Leopardi", "José Valim"]
    }
  end

  defp docs do
    [
      main: "Mix.Tasks.Compile.ElixirMake",
      source_ref: "v#{@version}",
      source_url: "https://github.com/elixir-lang/elixir_make"
    ]
  end
end
