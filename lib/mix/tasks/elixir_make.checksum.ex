defmodule Mix.Tasks.ElixirMake.Checksum do
  @shortdoc "Fetch precompiled NIFs and build the checksums"

  @moduledoc """
  A task responsible for downloading the precompiled NIFs for a given module.

  This task must only be used by package creators who want to ship the
  precompiled NIFs. The goal is to download the precompiled packages and
  generate a checksum to check-in alongside the project in the the Hex repository.
  This is done by passing the `--all` flag.

  You can also use the `--only-local` flag to download only the precompiled
  package for use during development.

  You can use the `--ignore-unavailable` flag to ignore any NIFs that are not available.
  This is useful when you are developing a new NIF that does not support all platforms.

  This task also accept the `--print` flag to print the checksums.
  """

  use Mix.Task

  @switches [
    all: :boolean,
    only_local: :boolean,
    print: :boolean,
    ignore_unavailable: :boolean
  ]

  @impl true
  def run(flags) when is_list(flags) do
    config = Mix.Project.config()

    precompiler =
      config[:precompiler] ||
        Mix.raise(
          ":make_precompiler project configuration is required when using elixir_make.checksum"
        )

    {options, _args} = OptionParser.parse!(flags, strict: @switches)

    urls =
      cond do
        Keyword.get(options, :all) ->
          ElixirMake.Artefact.available_nif_urls(precompiler)

        Keyword.get(options, :only_local) ->
          case ElixirMake.Artefact.current_target_nif_url(precompiler) do
            {:ok, target, url} -> [{target, url}]
            {:error, error} -> Mix.raise(error)
          end

        true ->
          Mix.raise("you need to specify either \"--all\" or \"--only-local\" flags")
      end

    result = ElixirMake.Artefact.download_nif_artefacts_with_checksums!(urls, options)

    if Keyword.get(options, :print) do
      result
      |> Enum.map(fn %{path: path, checksum: checksum} -> {Path.basename(path), checksum} end)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {file, checksum} -> "#{checksum}  #{file}" end)
      |> IO.puts()
    end

    ElixirMake.Artefact.write_checksum!(config[:app], result)
  end
end
