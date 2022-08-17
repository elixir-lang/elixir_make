defmodule Mix.Tasks.ElixirMake.Precompile do
  @shortdoc "Precompiles the given project for all targets"

  @moduledoc """
  Precompiles the given project for all targets.

  This is only supported if `make_precompiler` is specified.
  """
  use Mix.Task

  def run(args) do
    module = ensure_precompiler_module!(Mix.Project.config()[:make_precompiler])
    {:ok, _precompiled_artifacts} = module.precompile(args, module.all_supported_targets())

    if function_exported?(module, :post_precompile, 0) do
      module.post_precompile()
    else
      :ok
    end
  end

  defp ensure_precompiler_module!(nil) do
    Mix.raise("`make_precompiler` is not specified in `project`")
  end

  defp ensure_precompiler_module!(module) do
    if Code.ensure_loaded?(module) do
      module
    else
      Mix.raise("`make_precompiler` module `#{inspect(module)}` is not loaded")
    end
  end

  @doc false
  def build_native(args) do
    module = ensure_precompiler_module!(Mix.Project.config()[:make_precompiler])
    module.build_native(args)
  end

  @doc false
  def available_nif_urls() do
    if module = Mix.Project.config()[:make_precompiler] do
      ensure_precompiler_module!(module).available_nif_urls()
    else
      []
    end
  end

  @doc false
  def download_or_reuse_nif_file() do
    module = ensure_precompiler_module!(Mix.Project.config()[:make_precompiler])
    module.download_or_reuse_nif_file()
  end

  @doc false
  def current_target_nif_url() do
    module = ensure_precompiler_module!(Mix.Project.config()[:make_precompiler])
    module.current_target_nif_url()
  end
end
