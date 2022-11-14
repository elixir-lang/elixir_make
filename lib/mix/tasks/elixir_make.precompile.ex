defmodule Mix.Tasks.ElixirMake.Precompile do
  @shortdoc "Precompiles the given project for all targets"

  @moduledoc """
  Precompiles the given project for all targets.

  This task must only be used by package creators who want to ship the
  precompiled NIFs. This task is often used on CI to precompile
  for different targets.

  This is only supported if `:make_precompiler` is specified
  in your project configuration.
  """

  alias ElixirMake.Artefact
  require Logger
  use Mix.Task

  @impl true
  def run(args) do
    config = Mix.Project.config()
    paths = config[:make_precompiler_priv_paths] || ["."]

    {_, precompiler} =
      config[:make_precompiler] ||
        Mix.raise(
          ":make_precompiler project configuration is required when using elixir_make.precompile"
        )

    targets = precompiler.all_supported_targets(:compile)

    try do
      precompiled_artefacts =
        Enum.map(targets, fn target ->
          case precompiler.precompile(args, target) do
            :ok -> create_precompiled_archive(config, target, paths)
            {:error, msg} -> Mix.raise(msg)
          end
        end)

      Artefact.write_checksums!(precompiled_artefacts)

      if function_exported?(precompiler, :post_precompile, 0) do
        precompiler.post_precompile()
      else
        :ok
      end
    after
      app_priv = Path.join(Mix.Project.app_path(config), "priv")

      for include <- paths,
          file <- Path.wildcard(Path.join(app_priv, include)) do
        File.rm_rf(file)
      end
    end
  end

  defp create_precompiled_archive(config, target, paths) do
    archive_path = Artefact.archive_path(config, target)

    Mix.shell().info("Creating precompiled archive: #{archive_path}")
    Mix.shell().info("Paths to archive from priv directory: #{inspect(paths)}")

    app_priv = Path.join(Mix.Project.app_path(config), "priv")
    File.mkdir_p!(app_priv)
    File.mkdir_p!(Path.dirname(archive_path))

    artefact =
      File.cd!(app_priv, fn ->
        filepaths =
          for path <- paths,
              entry <- Path.wildcard(path),
              do: String.to_charlist(entry)

        Artefact.compress(archive_path, filepaths)
      end)

    Mix.shell().info(
      "NIF cached at #{archive_path} with checksum #{artefact.checksum} (#{artefact.checksum_algo})"
    )

    artefact
  end
end
