defmodule ElixirMake.Mixfile do
  use Mix.Project

  def project do
    [
      app: :elixir_make,
      version: "0.6.0",
      elixir: "~> 1.3",
      description: "A Make compiler for Mix",
      package: package(),
      deps: []
    ]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: []]
  end

  defp package do
    %{
      licenses: ["Apache 2"],
      links: %{"GitHub" => "https://github.com/elixir-lang/elixir_make"},
      maintainers: ["Andrea Leopardi", "José Valim"]
    }
  end
end
