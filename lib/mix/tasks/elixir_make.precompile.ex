defmodule Mix.Tasks.ElixirMake.Precompile do
  use Mix.Task

  @doc """
  The precompiler should compile for the host natively
  """
  @callback build_native(OptionParser.argv()) :: :ok | {:ok, []} | no_return

  @doc """
  The precompiler should download or reuse nif file for current target.

  ## Paramters

    - `context`: Precompiler context returned by the `precompiler_context` callback.
  """
  @callback download_or_reuse_nif_file(context :: term()) :: :ok | {:error, String.t()}

  @doc """
  Precompiler context
  """
  @callback precompiler_context(OptionParser.argv()) :: term()

  @doc """
  Post actions to run after all precompiling tasks
  """
  @callback post_precompile(context :: term()) :: :ok

  @doc """
  Returns URLs for NIFs based on its module name.
  The module name is the one that defined the NIF and this information
  is stored in a metadata file.
  """
  @callback available_nif_urls() :: [String.t()]

  @doc """
  Returns the file URL to be downloaded for current target.
  It receives the NIF module.
  """
  @callback current_target_nif_url() :: String.t()

  @impl true
  def run(args) do
    precompile(args, Mix.Project.config()[:make_precompiler])
  end

  defp ensure_precompiler_module!(module) do
    if Code.ensure_loaded?(module) do
      module
    else
      Mix.raise("requested precompiler module `#{inspect(module)}` is not loaded")
    end
  end

  defp precompile(args, module) when module != nil do
    module = ensure_precompiler_module!(Module.concat([Mix.Tasks.ElixirMake, module]))
    Kernel.apply(module, :run, [args])
    context = Kernel.apply(module, :precompiler_context, [args])
    Kernel.apply(module, :post_precompile, [context])
  end

  def build_native(args) do
    precompile_build_native(args, Mix.Project.config()[:make_precompiler])
  end

  defp precompile_build_native(args, nil) do
    ElixirMake.Compile.compile(args)
  end

  defp precompile_build_native(args, module) do
    module = ensure_precompiler_module!(Module.concat([Mix.Tasks.ElixirMake, module]))
    Kernel.apply(module, :build_native, [args])
  end

  def available_nif_urls() do
    available_nif_urls(Mix.Project.config()[:make_precompiler])
  end

  defp available_nif_urls(nil) do
    []
  end

  defp available_nif_urls(module) do
    module = ensure_precompiler_module!(Module.concat([Mix.Tasks.ElixirMake, module]))
    Kernel.apply(module, :available_nif_urls, [])
  end

  def download_or_reuse_nif_file(context) do
    download_or_reuse_nif_file(context, Mix.Project.config()[:make_precompiler])
  end

  defp download_or_reuse_nif_file(_context, nil) do
    {:error, "`make_precompiler` is not specified"}
  end

  defp download_or_reuse_nif_file(context, module) do
    module = ensure_precompiler_module!(Module.concat([Mix.Tasks.ElixirMake, module]))
    Kernel.apply(module, :download_or_reuse_nif_file, [context])
  end

  def current_target_nif_url() do
    current_target_nif_url(Mix.Project.config()[:make_precompiler])
  end

  def current_target_nif_url(nil) do
    {:error, "`make_precompiler` is not specified"}
  end

  def current_target_nif_url(module) do
    module = ensure_precompiler_module!(Module.concat([Mix.Tasks.ElixirMake, module]))
    Kernel.apply(module, :current_target_nif_url, [])
  end
end
