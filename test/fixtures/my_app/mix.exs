defmodule MyApp.Mixfile do
  use Mix.Project

  def project do
    [app: :my_app, version: "1.0.0", compilers: [:elixir_make]]
  end
end

defmodule MyApp.Precompiler do
  @behaviour ElixirMake.Precompiler

  @impl true
  def current_target, do: {:ok, "target"}

  @impl true
  def all_supported_targets(_), do: ["target"]

  @impl true
  def build_native(args), do: ElixirMake.Compiler.compile(args)

  @impl true
  def precompile(args, _target) do
    ElixirMake.Compiler.compile(args)
    :ok
  end
end
