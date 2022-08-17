defmodule Mix.Tasks.ElixirMake.Fetch do
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
  def run([]) do
    raise "the module name and a flag is expected. Use \"--all\" or \"--only-local\" flags"
  end

  @impl true
  def run(flags) when is_list(flags) do
    {options, _args, _invalid} = OptionParser.parse(flags, strict: @switches)

    urls =
      cond do
        Keyword.get(options, :all) ->
          Mix.Tasks.ElixirMake.Precompile.available_nif_urls()

        Keyword.get(options, :only_local) ->
          [Mix.Tasks.ElixirMake.Precompile.current_target_nif_url()]

        true ->
          raise "you need to specify either \"--all\" or \"--only-local\" flags"
      end

    result = ElixirMake.Artefact.download_nif_artifacts_with_checksums!(urls, options)

    if Keyword.get(options, :print) do
      result
      |> Enum.map(fn map ->
        {Path.basename(Map.fetch!(map, :path)), Map.fetch!(map, :checksum)}
      end)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {file, checksum} -> "#{checksum}  #{file}" end)
      |> IO.puts()
    end

    ElixirMake.Artefact.write_checksum!(Mix.Project.config()[:app], result)
  end
end
