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
  alias ElixirMake.Artefact

  @recursive true

  @switches [
    all: :boolean,
    only_local: :boolean,
    print: :boolean,
    ignore_unavailable: :boolean
  ]

  @impl true
  def run(flags) when is_list(flags) do
    if function_exported?(Mix, :ensure_application!, 1) do
      Mix.ensure_application!(:inets)
      Mix.ensure_application!(:ssl)
      Mix.ensure_application!(:crypto)
    end

    config = Mix.Project.config()

    {_, precompiler} =
      config[:make_precompiler] ||
        Mix.raise(
          ":make_precompiler project configuration is required when using elixir_make.checksum"
        )

    {options, _args} = OptionParser.parse!(flags, strict: @switches)

    urls =
      cond do
        Keyword.get(options, :all) ->
          Artefact.available_target_urls(config, precompiler)

        Keyword.get(options, :only_local) ->
          case Artefact.current_target_url(config, precompiler, :erlang.system_info(:nif_version)) do
            {:ok, target, url} ->
              [{{target, "#{:erlang.system_info(:nif_version)}"}, url}]

            {:error, {:unavailable_target, current_target, error}} ->
              recover =
                if function_exported?(precompiler, :unavailable_target, 1) do
                  precompiler.unavailable_target(current_target)
                else
                  :compile
                end

              case recover do
                :compile ->
                  Mix.raise(error)

                :ignore ->
                  []
              end

            {:error, error} ->
              Mix.raise(error)
          end

        true ->
          Mix.raise("you need to specify either \"--all\" or \"--only-local\" flags")
      end

    artefacts = download_and_checksum_all(urls, options)

    if Keyword.get(options, :print, false) do
      artefacts
      |> Enum.map(fn %Artefact{basename: basename, checksum: checksum} -> {basename, checksum} end)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {file, checksum} -> "#{checksum}  #{file}" end)
      |> IO.puts()
    end

    Artefact.write_checksums!(artefacts)
  end

  defp download_and_checksum_all(urls, options) do
    ignore_unavailable? = Keyword.get(options, :ignore_unavailable, false)

    tasks =
      Task.async_stream(
        urls,
        fn {{_target, _nif_version}, url} -> {url, Artefact.download(url)} end,
        timeout: :infinity,
        ordered: false
      )

    cache_dir = Artefact.cache_dir()

    Enum.flat_map(tasks, fn {:ok, {url, download}} ->
      case download do
        {:ok, body} ->
          basename = basename_from_url(url)
          path = Path.join(cache_dir, basename)
          File.write!(path, body)
          artefact = Artefact.checksum(basename, body)

          Mix.shell().info(
            "NIF cached at #{path} with checksum #{artefact.checksum} (#{artefact.checksum_algo})"
          )

          [artefact]

        result ->
          if ignore_unavailable? do
            msg = "Skipped unavailable NIF artifact. Reason: #{inspect(result)}"
            Mix.shell().info(msg)
          else
            msg = "Could not finish the download of NIF artifacts. Reason: #{inspect(result)}"
            Mix.shell().error(msg)
          end

          []
      end
    end)
  end

  defp basename_from_url(url) do
    uri = URI.parse(url)

    uri.path
    |> String.split("/")
    |> List.last()
  end
end
