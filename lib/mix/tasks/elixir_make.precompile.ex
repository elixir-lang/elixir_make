defmodule Mix.Tasks.ElixirMake.Precompile do
  @shortdoc "Precompiles the given project for all targets"

  @moduledoc """
  Precompiles the given project for all targets.

  This is only supported if `make_precompiler` is specified.
  """

  require Logger
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
    targets =
      ensure_precompiler_module!(Mix.Project.config()[:make_precompiler]).all_supported_targets()

    ElixirMake.Artefact.archive_download_url(targets)
  end

  @doc false
  def download_or_reuse_nif_file() do
    module = ensure_precompiler_module!(Mix.Project.config()[:make_precompiler])
    cache_dir = ElixirMake.Artefact.cache_dir()

    with {:ok, target} <- module.current_target() do
      app = Mix.Project.config()[:app]
      version = Mix.Project.config()[:version]
      nif_version = ElixirMake.Compile.current_nif_version()

      # note that `:cc_precompile_base_url` here is the key specific to
      #   this CCPrecompile demo, it's not required by the elixir_make.
      # you can use any name you want for your own precompiler
      base_url = Mix.Project.config()[:cc_precompile_base_url]

      tar_filename = ElixirMake.Artefact.archive_filename(app, version, nif_version, target)

      app_priv = ElixirMake.Artefact.app_priv(app)
      cached_tar_gz = Path.join([cache_dir, tar_filename])

      if !File.exists?(cached_tar_gz) do
        with :ok <- File.mkdir_p(cache_dir),
             {:ok, tar_gz} <-
               ElixirMake.Artefact.download_archived_artefact(base_url, tar_filename),
             :ok <- File.write(cached_tar_gz, tar_gz) do
          Logger.debug("NIF cached at #{cached_tar_gz} and extracted to #{app_priv}")
        end
      end

      with {:file_exists, true} <- {:file_exists, File.exists?(cached_tar_gz)},
           {:file_integrity, :ok} <-
             {:file_integrity, ElixirMake.Artefact.check_file_integrity(cached_tar_gz, app)},
           {:restore_nif, :ok} <-
             {:restore_nif, ElixirMake.Artefact.restore_nif_file(cached_tar_gz, app)} do
        :ok
      else
        # of course you can choose to build from scratch instead of letting elixir_make
        # to raise an error
        {:file_exists, false} ->
          {:error, "Cache file not exists or cannot download"}

        {:file_integrity, _} ->
          {:error, "Cache file integrity check failed"}

        {:restore_nif, status} ->
          {:error, "Cannot restore nif from cache: #{inspect(status)}"}
      end
    end
  end

  @doc false
  def current_target_nif_url() do
    module = ensure_precompiler_module!(Mix.Project.config()[:make_precompiler])
    current_target = module.current_target()

    current =
      Enum.reject(available_nif_urls(), fn {target, _url} ->
        target != current_target
      end)

    case current do
      [{^current_target, download_url}] ->
        {current_target, download_url}

      [] ->
        Mix.raise("Cannot find download url for current target `#{current_target}`")
    end
  end
end
