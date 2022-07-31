defmodule Mix.Tasks.ElixirMake.Compile do
  @moduledoc """
  Runs `make` in the current project.

  This task runs `make` in the current project; any output coming from `make` is
  printed in real-time on stdout.
  """

  use Mix.Task

  def run(args) do
    Mix.Tasks.ElixirMake.Precompile.build_native(args)
  end
end
