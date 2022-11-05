defmodule Mix.Tasks.ElixirMake.Precompile do
  @shortdoc "Precompiles the given project for all targets"

  @moduledoc """
  Precompiles the given project for all targets.

  This is only supported if `make_precompiler` is specified.
  """

  alias ElixirMake.{Artefact, Precompiler}
  require Logger
  use Mix.Task

  @impl true
  def run(args) do
    config = Mix.Project.config()
    app = config[:app]
    paths = config[:make_precompiler_priv_paths] || ["."]
    version = config[:version]
    nif_version = Precompiler.current_nif_version()

    precompiler =
      config[:make_precompiler] ||
        Mix.raise(
          ":make_precompiler project configuration is required when using elixir_make.precompile"
        )

    cache_dir =
      if function_exported?(precompiler, :cache_dir, 0) do
        precompiler.cache_dir()
      else
        Precompiler.cache_dir()
      end

    targets = precompiler.all_supported_targets(:compile)

    precompiled_artefacts =
      Enum.map(targets, fn target ->
        {_archive_full_path, archived_filename, checksum_algo, checksum} =
          case precompiler.precompile(args, target) do
            :ok ->
              Artefact.create_precompiled_archive(
                app,
                version,
                nif_version,
                target,
                cache_dir,
                paths
              )

            {:error, msg} ->
              Mix.raise(msg)
          end

        {target, %{path: archived_filename, checksum_algo: checksum_algo, checksum: checksum}}
      end)

    Artefact.write_checksum!(app, precompiled_artefacts)

    if function_exported?(precompiler, :post_precompile, 0) do
      precompiler.post_precompile()
    else
      :ok
    end

    with {:ok, target} <- precompiler.current_target() do
      archived_filename = Artefact.archive_filename(app, version, nif_version, target)
      archived_fullpath = Path.join([cache_dir, archived_filename])
      Artefact.restore_nif_file(archived_fullpath, app)
    end

    Mix.Project.build_structure()
  end
end
