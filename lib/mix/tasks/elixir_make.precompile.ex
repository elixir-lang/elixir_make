defmodule Mix.Tasks.ElixirMake.Precompile do
  @shortdoc "Precompiles the given project for all targets"

  @moduledoc """
  Precompiles the given project for all targets.

  This is only supported if `make_precompiler` is specified.
  """

  require Logger
  use Mix.Task

  @impl true
  def run(args) do
    module = ensure_precompiler_module!(Mix.Project.config()[:make_precompiler])
    config = Mix.Project.config()
    app = config[:app]
    version = config[:version]
    nif_version = ElixirMake.Compile.current_nif_version()

    # get precompiler module's specific cache directory if applicable
    cache_dir =
      if function_exported?(module, :cache_dir, 0) do
        module.cache_dir()
      else
        ElixirMake.Artefact.cache_dir()
      end

    targets = module.all_supported_targets(:compile)

    precompiled_artefacts =
      Enum.reduce(targets, [], fn target, checksums ->
        {_archive_full_path, archived_filename, checksum_algo, checksum} =
          with :ok <- module.precompile(args, target) do
            ElixirMake.Artefact.create_precompiled_archive(
              app,
              version,
              nif_version,
              target,
              cache_dir
            )
          else
            {:error, msg} ->
              Mix.raise(msg)
          end

        [
          {target, %{path: archived_filename, checksum_algo: checksum_algo, checksum: checksum}}
          | checksums
        ]
      end)

    ElixirMake.Artefact.write_checksum!(app, precompiled_artefacts)

    if function_exported?(module, :post_precompile, 0) do
      module.post_precompile()
    else
      :ok
    end

    with {:ok, target} <- module.current_target() do
      archived_filename = ElixirMake.Artefact.archive_filename(app, version, nif_version, target)
      archived_fullpath = Path.join([cache_dir, archived_filename])
      ElixirMake.Artefact.restore_nif_file(archived_fullpath, app)
    end

    Mix.Project.build_structure()
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
      ensure_precompiler_module!(Mix.Project.config()[:make_precompiler]).all_supported_targets(
        :fetch
      )

    ElixirMake.Artefact.archive_download_url(targets)
  end

  @doc false
  def download_or_reuse_nif_file(args) do
    with {target, url} <- current_target_nif_url() do
      cache_dir = ElixirMake.Artefact.cache_dir()

      app = Mix.Project.config()[:app]
      version = Mix.Project.config()[:version]
      nif_version = ElixirMake.Compile.current_nif_version()
      archived_filename = ElixirMake.Artefact.archive_filename(app, version, nif_version, target)

      app_priv = ElixirMake.Artefact.app_priv(app)
      archived_fullpath = Path.join([cache_dir, archived_filename])

      if !File.exists?(archived_fullpath) do
        with :ok <- File.mkdir_p(cache_dir),
            {:ok, archived_data} <- ElixirMake.Artefact.download_nif_artefact(url),
            :ok <- File.write(archived_fullpath, archived_data) do
          Logger.debug("NIF cached at #{archived_fullpath} and extracted to #{app_priv}")
        end
      end

      with {:file_exists, true} <- {:file_exists, File.exists?(archived_fullpath)},
          {:file_integrity, :ok} <-
            {:file_integrity, ElixirMake.Artefact.check_file_integrity(archived_fullpath, app)},
          {:restore_nif, :ok} <-
            {:restore_nif, ElixirMake.Artefact.restore_nif_file(archived_fullpath, app)} do
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
    else
      :build_from_source ->
        build_native(args)
    end
  end

  @doc false
  def current_target_nif_url() do
    module = ensure_precompiler_module!(Mix.Project.config()[:make_precompiler])

    with {:ok, current_target} <- module.current_target() do
      available_urls = available_nif_urls()

      current =
        Enum.reject(available_urls, fn {target, _url} ->
          target != current_target
        end)

      case current do
        [{^current_target, download_url}] ->
          {current_target, download_url}

        [] ->
          available_targets = Enum.map(available_urls, fn {target, _url} -> target end)

          Logger.warning(
            "Cannot find download url for current target `#{inspect(current_target)}`, will try to build from source. Available targets are: #{inspect(available_targets)}"
          )

          :build_from_source
      end
    else
      {:error, msg} -> Mix.raise(msg)
    end
  end
end
