defmodule Mix.Tasks.ElixirMake.Precompile do
  use Mix.Task

  @callback build_native(OptionParser.argv()) :: :ok | {:ok, []} | no_return
  @callback download_or_reuse_nif_file(term) :: :ok | {:error, String.t()}
  @callback precompiler_context(OptionParser.argv()) :: term()

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

  defp precompile(args, FennecPrecompile) do
    Mix.Tasks.ElixirMake.FennecPrecompile.run(args)
  end

  def build_native(args) do
    precompile_build_native(args, Mix.Project.config()[:make_precompiler])
  end

  defp precompile_build_native(args, nil) do
    ElixirMake.Compile.compile(args)
  end

  defp precompile_build_native(args, FennecPrecompile) do
    Mix.Tasks.ElixirMake.FennecPrecompile.build_native(args)
  end

  def available_nif_urls() do
    available_nif_urls(Mix.Project.config()[:make_precompiler])
  end

  defp available_nif_urls(nil) do
    []
  end

  defp available_nif_urls(FennecPrecompile) do
    Mix.Tasks.ElixirMake.FennecPrecompile.available_nif_urls()
  end

  def download_or_reuse_nif_file(context) do
    download_or_reuse_nif_file(context, Mix.Project.config()[:make_precompiler])
  end

  defp download_or_reuse_nif_file(_context, nil) do
    {:error, "`make_precompiler` is not specified"}
  end

  defp download_or_reuse_nif_file(context, FennecPrecompile) do
    Mix.Tasks.ElixirMake.FennecPrecompile.download_or_reuse_nif_file(context)
  end

  def current_target_nif_url() do
    current_target_nif_url(Mix.Project.config()[:make_precompiler])
  end

  def current_target_nif_url(nil) do
    {:error, "`make_precompiler` is not specified"}
  end

  def current_target_nif_url(FennecPrecompile) do
    Mix.Tasks.ElixirMake.FennecPrecompile.current_target_nif_url()
  end
end
