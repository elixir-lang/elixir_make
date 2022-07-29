defmodule Mix.Tasks.ElixirMake.Precompile do
  use Mix.Task

  @doc """
  This callback will be invoked when the user executes the `mix compile`
  (or `mix compile.elixir_make`) command.

  The precompiler should then compile the NIF library "natively". Note that
  it is possible for the precompiler module to pick up other environment variables
  like `TARGET_ARCH=aarch64` and adjust compile arguments correspondingly.
  """
  @callback build_native(OptionParser.argv()) :: :ok | {:ok, []} | no_return

  @doc """
  This callback will be invoked when the NIF library is trying to load functions
  from its shared library.

  The precompiler should download or reuse nif file for current target.

  ## Paramters

    - `context`: Precompiler context returned by the `precompiler_context` callback.

  """
  @callback download_or_reuse_nif_file(context :: term()) :: :ok | {:error, String.t()} | no_return

  @doc """
  This callback will be invoked when the user executes the following commands:

  - `mix elixir_make.fetch --all`
  - `mix elixir_make.fetch --all --print`

  The precompiler module should return all available URLs to precompiled artefacts
  of the NIF library.
  """
  @callback available_nif_urls() :: [String.t()]

  @doc """
  This callback will be invoked when the user executes the following commands:

  - `mix elixir_make.fetch --only-local`
  - `mix elixir_make.fetch --only-local --print`

  The precompiler module should return the URL to a precompiled artefact of
  the NIF library for current target (the "native" host).
  """
  @callback current_target_nif_url() :: String.t()

  @doc """
  This optional callback is designed to store the precompiler's state or context.

  The returned value will be used in the `download_or_reuse_nif_file/1` and
  `post_precompile/1` callback.
  """
  @callback precompiler_context(OptionParser.argv()) :: term()

  @doc """
  This optional callback will be invoked when all precompilation tasks are done,
  i.e., it will only be called at the end of the `mix elixir_make.precompile`
  command.

  Post actions to run after all precompilation tasks are done. For example,
  actions can be archiving all precompiled artefacts and uploading the archive
  file to an object storage server.
  """
  @callback post_precompile(context :: term()) :: :ok

  @impl true
  def run(args) do
    precompile(args, Mix.Project.config()[:make_precompiler])
  end

  defp ensure_precompiler_module!(module) do
    module = Module.concat([Mix.Tasks.ElixirMake, module])
    if Code.ensure_loaded?(module) do
      module
    else
      Mix.raise("requested precompiler module `#{inspect(module)}` is not loaded")
    end
  end

  defp precompile(args, module) when module != nil do
    module = ensure_precompiler_module!(module)
    ret = Kernel.apply(module, :run, [args])

    context =
      if Kernel.function_exported?(module, :precompiler_context, 1) do
        Kernel.apply(module, :precompiler_context, [args])
      else
        nil
      end

    if Kernel.function_exported?(module, :post_precompile, 1) do
      Kernel.apply(module, :post_precompile, [context])
    else
      ret
    end
  end

  def build_native(args) do
    precompile_build_native(args, Mix.Project.config()[:make_precompiler])
  end

  defp precompile_build_native(args, nil) do
    ElixirMake.Compile.compile(args)
  end

  defp precompile_build_native(args, module) do
    module = ensure_precompiler_module!(module)
    Kernel.apply(module, :build_native, [args])
  end

  def available_nif_urls() do
    available_nif_urls(Mix.Project.config()[:make_precompiler])
  end

  defp available_nif_urls(nil) do
    []
  end

  defp available_nif_urls(module) do
    module = ensure_precompiler_module!(module)
    Kernel.apply(module, :available_nif_urls, [])
  end

  def download_or_reuse_nif_file(context) do
    download_or_reuse_nif_file(context, Mix.Project.config()[:make_precompiler])
  end

  defp download_or_reuse_nif_file(_context, nil) do
    {:error, "`make_precompiler` is not specified"}
  end

  defp download_or_reuse_nif_file(context, module) do
    module = ensure_precompiler_module!(module)
    Kernel.apply(module, :download_or_reuse_nif_file, [context])
  end

  def current_target_nif_url() do
    current_target_nif_url(Mix.Project.config()[:make_precompiler])
  end

  def current_target_nif_url(nil) do
    {:error, "`make_precompiler` is not specified"}
  end

  def current_target_nif_url(module) do
    module = ensure_precompiler_module!(module)
    Kernel.apply(module, :current_target_nif_url, [])
  end
end
