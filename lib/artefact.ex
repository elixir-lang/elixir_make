defmodule ElixirMake.Artefact do
  require Logger

  @checksum_algo :sha256
  @checksum_algorithms [@checksum_algo]
  def checksum_algo, do: @checksum_algo

  def compute_checksum(file_path, algo) do
    case File.read(file_path) do
      {:ok, content} ->
        file_hash =
          algo
          |> :crypto.hash(content)
          |> Base.encode16(case: :lower)

        {:ok, "#{algo}", "#{file_hash}"}

      {:error, reason} ->
        {:error,
         "cannot read the file for checksum comparison: #{inspect(file_path)}. " <>
           "Reason: #{inspect(reason)}"}
    end
  end

  def compare_checksum(file_path, algo, expected_checksum) do
    case compute_checksum(file_path, algo) do
      {:ok, _, file_hash} ->
        if file_hash == expected_checksum do
          :ok
        else
          {:error, "the integrity check failed because the checksum of files does not match"}
        end

      {:error, reason} ->
        {:error,
         "cannot read the file for checksum comparison: #{inspect(file_path)}. " <>
           "Reason: #{inspect(reason)}"}
    end
  end

  # Download a list of files from URLs and calculate its checksum.
  # Returns a list with details of the download and the checksum of each file.
  @doc false
  def download_nif_artifacts_with_checksums!(urls, options \\ []) do
    ignore_unavailable? = Keyword.get(options, :ignore_unavailable, false)

    tasks =
      Task.async_stream(urls, fn url -> {url, download_nif_artifact(url)} end, timeout: :infinity)

    cache_dir = System.get_env("ELIXIE_MAKE_CACHE_DIR", ElixirMake.Artefact.cache_dir())

    Enum.flat_map(tasks, fn {:ok, result} ->
      with {:download, {url, download_result}} <- {:download, result},
           {:download_result, {:ok, body}} <- {:download_result, download_result},
           hash <- :crypto.hash(@checksum_algo, body),
           path <- Path.join(cache_dir, basename_from_url(url)),
           {:file, :ok} <- {:file, File.write(path, body)} do
        checksum = Base.encode16(hash, case: :lower)

        Logger.debug(
          "NIF cached at #{path} with checksum #{inspect(checksum)} (#{@checksum_algo})"
        )

        [
          %{
            url: url,
            path: path,
            checksum: checksum,
            checksum_algo: @checksum_algo
          }
        ]
      else
        {:file, error} ->
          raise "could not write downloaded file to disk. Reason: #{inspect(error)}"

        {context, result} ->
          if ignore_unavailable? do
            Logger.debug(
              "Skip an unavailable NIF artifact. " <>
                "Context: #{inspect(context)}. Reason: #{inspect(result)}"
            )

            []
          else
            raise "could not finish the download of NIF artifacts. " <>
                    "Context: #{inspect(context)}. Reason: #{inspect(result)}"
          end
      end
    end)
  end

  defp basename_from_url(url) do
    uri = URI.parse(url)

    uri.path
    |> String.split("/")
    |> List.last()
  end

  defp checksum_map(app) when is_atom(app) do
    checksum_file(app)
    |> read_map_from_file()
  end

  def check_file_integrity(file_path, app) when is_atom(app) do
    checksum_map(app)
    |> check_integrity_from_map(file_path)
  end

  # It receives the map of %{ "filename" => "algo:checksum" } with the file path
  @doc false
  def check_integrity_from_map(checksum_map, file_path) do
    with {:ok, {algo, hash}} <- find_checksum(checksum_map, file_path),
         :ok <- validate_checksum_algo(algo) do
      compare_checksum(file_path, algo, hash)
    end
  end

  defp find_checksum(checksum_map, file_path) do
    basename = Path.basename(file_path)

    case Map.fetch(checksum_map, basename) do
      {:ok, algo_with_hash} ->
        [algo, hash] = String.split(algo_with_hash, ":")
        algo = String.to_existing_atom(algo)

        {:ok, {algo, hash}}

      :error ->
        {:error,
         "the precompiled NIF file does not exist in the checksum file. " <>
           "Please consider run: `mix elixir_make.fetch #{Mix.Project.config()[:app]} --only-local` to generate the checksum file."}
    end
  end

  defp validate_checksum_algo(algo) do
    if algo in @checksum_algorithms do
      :ok
    else
      {:error,
       "checksum algorithm is not supported: #{inspect(algo)}. " <>
         "The supported ones are:\n - #{Enum.join(@checksum_algorithms, "\n - ")}"}
    end
  end

  def download_nif_artifact(url) do
    url = String.to_charlist(url)
    Logger.debug("Downloading NIF from #{url}")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    if proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy") do
      Logger.debug("Using HTTP_PROXY: #{proxy}")
      %{host: host, port: port} = URI.parse(proxy)

      :httpc.set_options([{:proxy, {{String.to_charlist(host), port}, []}}])
    end

    if proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") do
      Logger.debug("Using HTTPS_PROXY: #{proxy}")
      %{host: host, port: port} = URI.parse(proxy)
      :httpc.set_options([{:https_proxy, {{String.to_charlist(host), port}, []}}])
    end

    # https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/inets
    cacertfile = CAStore.file_path() |> String.to_charlist()

    http_options = [
      ssl: [
        verify: :verify_peer,
        cacertfile: cacertfile,
        depth: 2,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    options = [body_format: :binary]

    case :httpc.request(:get, {url, []}, http_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      other ->
        {:error, "couldn't fetch NIF from #{url}: #{inspect(other)}"}
    end
  end

  # Write the checksum file with all NIFs available.
  # It receives the module name and checksums.
  @doc false
  def write_checksum!(app, precompiled_artefacts) do
    file = checksum_file(app)

    pairs =
      for {_target, %{path: path, checksum: checksum, checksum_algo: algo}} <-
            precompiled_artefacts,
          into: %{} do
        basename = Path.basename(path)
        checksum = "#{algo}:#{checksum}"
        {basename, checksum}
      end

    lines =
      for {filename, checksum} <- Enum.sort(pairs) do
        ~s(  "#{filename}" => #{inspect(checksum, limit: :infinity)},\n)
      end

    File.write!(file, ["%{\n", lines, "}\n"])
  end

  defp checksum_file(app) when is_atom(app) do
    # Saves the file in the project root.
    Path.join(File.cwd!(), "checksum-#{to_string(app)}.exs")
  end

  def download_archived_artefact(base_url, tar_filename) do
    "#{base_url}/#{tar_filename}"
    |> download_nif_artifact()
  end

  @doc """
  Returns user cache directory.
  """
  def cache_dir(sub_dir \\ "") do
    cache_opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}
    cache_dir = :filename.basedir(:user_cache, "", cache_opts)

    cache_dir =
      System.get_env("ELIXIR_MAKE_CACHE_DIR", cache_dir)
      |> Path.join(sub_dir)

    File.mkdir_p!(cache_dir)
    cache_dir
  end

  def create_precompiled_archive(app, version, nif_version, target, cache_dir) do
    saved_cwd = File.cwd!()

    app_priv = app_priv(app)
    File.cd!(app_priv)

    archive_tar_gz = archive_filename(app, version, nif_version, target)
    archive_full_path = Path.expand(Path.join([cache_dir, archive_tar_gz]))
    File.mkdir_p!(cache_dir)
    Logger.debug("Creating precompiled archive: #{archive_full_path}")

    filelist = build_file_list_at(app_priv)
    File.cd!(app_priv)
    :ok = :erl_tar.create(archive_full_path, filelist, [:compressed])

    File.cd!(saved_cwd)

    {:ok, algo, checksum} =
      ElixirMake.Artefact.compute_checksum(archive_full_path, ElixirMake.Artefact.checksum_algo())

    {archive_full_path, archive_tar_gz, algo, checksum}
  end

  def archive_filename(app, version, nif_version, target) do
    "#{app}-nif-#{nif_version}-#{target}-#{version}.tar.gz"
  end

  defp build_file_list_at(dir) do
    saved_cwd = File.cwd!()
    File.cd!(dir)
    {filelist, _} = build_file_list_at(".", %{}, [])
    File.cd!(saved_cwd)
    Enum.map(filelist, &to_charlist/1)
  end

  defp build_file_list_at(dir, visited, filelist) do
    visited? = Map.get(visited, dir)

    if visited? do
      {filelist, visited}
    else
      visited = Map.put(visited, dir, true)
      saved_cwd = File.cwd!()

      case {File.dir?(dir), File.read_link(dir)} do
        {true, {:error, _}} ->
          File.cd!(dir)
          cur_filelist = File.ls!()

          {files, folders} =
            Enum.reduce(cur_filelist, {[], []}, fn filepath, {files, folders} ->
              if File.dir?(filepath) do
                symlink_dir? = Path.join([File.cwd!(), filepath])

                case File.read_link(symlink_dir?) do
                  {:error, _} ->
                    {files, [filepath | folders]}

                  {:ok, _} ->
                    {[Path.join([dir, filepath]) | files], folders}
                end
              else
                {[Path.join([dir, filepath]) | files], folders}
              end
            end)

          File.cd!(saved_cwd)

          filelist = files ++ filelist ++ [dir]

          {files_in_folder, visited} =
            Enum.reduce(folders, {[], visited}, fn folder_path, {files_in_folder, visited} ->
              {filelist, visited} =
                build_file_list_at(Path.join([dir, folder_path]), visited, files_in_folder)

              {files_in_folder ++ filelist, visited}
            end)

          filelist = filelist ++ files_in_folder
          {filelist, visited}

        _ ->
          {filelist, visited}
      end
    end
  end

  def app_priv(app) when is_atom(app) do
    build_path = Mix.Project.build_path()
    Path.join([build_path, "lib", "#{app}", "priv"])
  end

  def make_priv_dir(app, :clean) when is_atom(app) do
    app_priv = app_priv(app)
    File.rm_rf!(app_priv)
    make_priv_dir(app)
  end

  def make_priv_dir(app) when is_atom(app) do
    File.mkdir_p!(app_priv(app))
  end

  def restore_nif_file(cached_tar_gz, app) do
    Logger.debug("Restore NIF for current node from: #{cached_tar_gz}")
    :erl_tar.extract(cached_tar_gz, [:compressed, {:cwd, to_string(app_priv(app))}])
  end

  defp read_map_from_file(file) do
    with {:ok, contents} <- File.read(file),
         {%{} = contents, _} <- Code.eval_string(contents) do
      contents
    else
      _ -> %{}
    end
  end

  def write_metadata(app, metadata) do
    metadata_file = metadata_file(app)
    existing = read_map_from_file(metadata_file)

    unless Map.equal?(metadata, existing) do
      dir = Path.dirname(metadata_file)
      :ok = File.mkdir_p(dir)

      File.write!(metadata_file, inspect(metadata, limit: :infinity, pretty: true))
    end

    :ok
  end

  defp metadata_file(app) do
    ElixirMake.Artefact.cache_dir()
    |> Path.join("metadata")
    |> Path.join("metadata-#{app}.exs")
  end

  def archive_file_url(base_url, file_name) do
    uri = URI.parse(base_url)

    uri =
      Map.update!(uri, :path, fn path ->
        Path.join(path || "", file_name)
      end)

    to_string(uri)
  end

  def metadata(app) do
    app
    |> metadata_file()
    |> read_map_from_file()
  end
end
