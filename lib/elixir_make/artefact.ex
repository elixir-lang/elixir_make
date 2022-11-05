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
      {:ok, _, ^expected_checksum} ->
        :ok

      {:ok, _, _} ->
        {:error, "files checksum do not match"}

      {:error, reason} ->
        {:error,
         "cannot read the file for checksum comparison: #{inspect(file_path)} (#{inspect(reason)})"}
    end
  end

  # Download a list of files from URLs and calculate its checksum.
  # Returns a list with details of the download and the checksum of each file.
  @doc false
  def download_nif_artefacts_with_checksums!(urls, options \\ []) do
    ignore_unavailable? = Keyword.get(options, :ignore_unavailable, false)

    tasks =
      Task.async_stream(
        urls,
        fn {_target, url} -> {url, download_nif_artefact(url)} end,
        timeout: :infinity,
        ordered: false
      )

    cache_dir = ElixirMake.Precompiler.cache_dir()

    Enum.flat_map(tasks, fn {:ok, {url, download}} ->
      case download do
        {:ok, body} ->
          hash = :crypto.hash(@checksum_algo, body)
          path = Path.join(cache_dir, basename_from_url(url))
          File.write!(path, body)

          checksum = Base.encode16(hash, case: :lower)

          Logger.debug(
            "NIF cached at #{path} with checksum #{inspect(checksum)} (#{@checksum_algo})"
          )

          [%{url: url, path: path, checksum: checksum, checksum_algo: @checksum_algo}]

        result ->
          if ignore_unavailable? do
            Logger.info("Skipped unavailable NIF artifact. Reason: #{inspect(result)}")
            []
          else
            # Only `raise` is not enough because if the library is used as a dependency in an app
            # the user won't see the error message but only
            #   `could not compile dependency :some_app, "mix compile" failed. Errors may have been logged above.`
            # So we have to explicitly log the error message
            msg = "could not finish the download of NIF artifacts. Reason: #{inspect(result)}"
            Logger.error(msg)
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
    |> check_integrity_from_map(app, file_path)
  end

  # It receives the map of %{ "filename" => "algo:checksum" } with the file path
  @doc false
  def check_integrity_from_map(checksum_map, app, file_path) do
    with {:ok, {algo, hash}} <- find_checksum(checksum_map, app, file_path),
         :ok <- validate_checksum_algo(algo) do
      compare_checksum(file_path, algo, hash)
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_checksum(checksum_map, app, file_path) do
    basename = Path.basename(file_path)

    if Enum.count(Map.keys(checksum_map)) > 0 do
      case Map.fetch(checksum_map, basename) do
        {:ok, algo_with_hash} ->
          [algo, hash] = String.split(algo_with_hash, ":")
          algo = String.to_existing_atom(algo)

          {:ok, {algo, hash}}

        :error ->
          {:error, "precompiled tar file does not exist in the checksum file, `checksum-#{app}.exs`."}
      end
    else
      {:error, "missing checksum file `checksum-#{app}.exs`"}
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

  def otp_version do
    :erlang.system_info(:otp_release) |> List.to_integer()
  end

  # Write the checksum file with all NIFs available.
  # It receives the module name and checksums.
  @doc false
  def write_checksum!(app, precompiled_artefacts) do
    file = checksum_file(app)

    pairs =
      for %{path: path, checksum: checksum, checksum_algo: algo} <-
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

  def create_precompiled_archive(app, version, nif_version, target, cache_dir, paths) do
    app_priv = app_priv(app)

    archived_filename = archive_filename(app, version, nif_version, target)
    archive_full_path = Path.expand(Path.join([cache_dir, archived_filename]))
    File.mkdir_p!(cache_dir)
    Logger.debug("Creating precompiled archive: #{archive_full_path}")
    Logger.debug("Paths to compress in priv directory: #{inspect(paths)}")

    saved_cwd = File.cwd!()
    File.cd!(app_priv)

    filepaths =
      Enum.reduce(paths, [], fn include, filepaths ->
        Enum.map(Path.wildcard(include), &to_charlist/1) ++ filepaths
      end)

    :ok = :erl_tar.create(archive_full_path, filepaths, [:compressed])
    File.cd!(saved_cwd)

    {:ok, algo, checksum} =
      ElixirMake.Artefact.compute_checksum(archive_full_path, ElixirMake.Artefact.checksum_algo())

    {archive_full_path, archived_filename, algo, checksum}
  end

  def archive_filename(app, version, nif_version, target) do
    "#{app}-nif-#{nif_version}-#{target}-#{version}.tar.gz"
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

  def restore_nif_file(cached_archive, app) do
    Logger.debug("Restore NIF for current node from: #{cached_archive}")
    :erl_tar.extract(cached_archive, [:compressed, {:cwd, to_string(app_priv(app))}])
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
    Logger.debug("metadata_file: #{inspect(metadata_file)}")
    existing = read_map_from_file(metadata_file)

    unless Map.equal?(metadata, existing) do
      dir = Path.dirname(metadata_file)
      :ok = File.mkdir_p(dir)

      File.write!(metadata_file, inspect(metadata, limit: :infinity, pretty: true))
    end

    :ok
  end

  defp metadata_file(app) do
    ElixirMake.Precompiler.cache_dir()
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

  ## NIF URLs

  def available_nif_urls(precompiler) do
    config = Mix.Project.config()
    targets = precompiler.all_supported_targets(:fetch)

    url_template =
      config[:make_precompiled_url] ||
        Mix.raise("`make_precompiled_url` is not specified in `project`")

    app = config[:app]
    version = config[:version]
    nif_version = ElixirMake.Precompiler.current_nif_version()

    Enum.map(targets, fn target ->
      archive_filename = archive_filename(app, version, nif_version, target)
      {target, String.replace(url_template, "@{artefact_filename}", archive_filename)}
    end)
  end

  def current_target_nif_url(precompiler) do
    case precompiler.current_target() do
      {:ok, current_target} ->
        available_urls = available_nif_urls(precompiler)

        case List.keyfind(available_urls, current_target, 0) do
          {^current_target, download_url} ->
            {:ok, current_target, download_url}

          nil ->
            available_targets = Enum.map(available_urls, fn {target, _url} -> target end)

            {:error,
             "cannot find download url for current target `#{inspect(current_target)}`. Available targets are: #{inspect(available_targets)}"}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  ## Download

  def download_nif_artefact(url) do
    url_charlist = String.to_charlist(url)
    Logger.debug("Downloading NIF from #{url}")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:public_key)

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
    # TODO: This may no longer be necessary from Erlang/OTP 25.0 or later.
    https_options = [
      ssl: [
        verify: :verify_peer,
        cacertfile: certificate_store(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    options = [body_format: :binary]

    case :httpc.request(:get, {url_charlist, []}, https_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      other ->
        {:error, "couldn't fetch NIF from #{url}: #{inspect(other)}"}
    end
  end

  # https_opts and related code are taken from
  # https://github.com/elixir-cldr/cldr_utils/blob/master/lib/cldr/http/http.ex
  @certificate_locations ([
                            # Configured cacertfile
                            System.get_env("ELIXIR_MAKE_CACERT")
                          ] ++
                            (if function_exported?(Mix.ProjectStack, :project_file, 0) do
                               [
                                 # A little hack to use cacerts.pem in CAStore
                                 Path.join([
                                   Path.dirname(Mix.ProjectStack.project_file()),
                                   "deps/castore/priv/cacerts.pem"
                                 ]),

                                 # A little hack to use cacerts.pem in :certfi
                                 Path.join([
                                   Path.dirname(Mix.ProjectStack.project_file()),
                                   "deps/certfi/priv/cacerts.pem"
                                 ])
                               ]
                             else
                               []
                             end) ++
                            [
                              # Debian/Ubuntu/Gentoo etc.
                              "/etc/ssl/certs/ca-certificates.crt",

                              # Fedora/RHEL 6
                              "/etc/pki/tls/certs/ca-bundle.crt",

                              # OpenSUSE
                              "/etc/ssl/ca-bundle.pem",

                              # OpenELEC
                              "/etc/pki/tls/cacert.pem",

                              # CentOS/RHEL 7
                              "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",

                              # Open SSL on MacOS
                              "/usr/local/etc/openssl/cert.pem",

                              # MacOS & Alpine Linux
                              "/etc/ssl/cert.pem"
                            ])
                         |> Enum.reject(&is_nil/1)

  defp certificate_store do
    @certificate_locations
    |> Enum.find(&File.exists?/1)
    |> warning_if_no_cacertfile!
    |> :erlang.binary_to_list()
  end

  defp warning_if_no_cacertfile!(nil) do
    Logger.warning("""
    No certificate trust store was found.

    Tried looking for: #{inspect(@certificate_locations)}

    A certificate trust store is required in
    order to download locales for your configuration.
    Since elixir_make could not detect a system
    installed certificate trust store one of the
    following actions may be taken:

    1. Install the hex package `castore`. It will
       be automatically detected after recompilation.

    2. Install the hex package `certifi`. It will
       be automatically detected after recompilation.

    3. Specify the location of a certificate trust store
       by configuring it in environment variable:

         export ELIXIR_MAKE_CACERT="/path/to/cacerts.pem"
    """)

    ""
  end

  defp warning_if_no_cacertfile!(file) do
    file
  end
end
