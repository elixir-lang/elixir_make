defmodule ElixirMake.Artefact do
  @moduledoc false
  require Logger

  @checksum_algo :sha256
  @checksum_algorithms [@checksum_algo]

  @doc """
  The checksum algorithm used.
  """
  def checksum_algo, do: @checksum_algo

  @doc """
  Returns user cache directory.
  """
  def cache_dir(sub_dir \\ "") do
    cache_opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}
    cache_dir = :filename.basedir(:user_cache, "", cache_opts)
    cache_dir = System.get_env("ELIXIR_MAKE_CACHE_DIR", cache_dir) |> Path.join(sub_dir)
    File.mkdir_p!(cache_dir)
    cache_dir
  end

  ## TODO

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

    cache_dir = cache_dir()

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

  defp checksum_map() do
    checksum_file()
    |> read_map_from_file()
  end

  def check_file_integrity(file_path) do
    checksum_map()
    |> check_integrity_from_map(file_path)
  end

  # It receives the map of %{ "filename" => "algo:checksum" } with the file path
  @doc false
  def check_integrity_from_map(checksum_map, file_path) do
    with {:ok, {algo, hash}} <- find_checksum(checksum_map, file_path),
         :ok <- validate_checksum_algo(algo) do
      compare_checksum(file_path, algo, hash)
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_checksum(checksum_map, file_path) do
    basename = Path.basename(file_path)

    if Enum.count(Map.keys(checksum_map)) > 0 do
      case Map.fetch(checksum_map, basename) do
        {:ok, algo_with_hash} ->
          [algo, hash] = String.split(algo_with_hash, ":")
          algo = String.to_existing_atom(algo)

          {:ok, {algo, hash}}

        :error ->
          {:error, "precompiled tar file does not exist in checksum.exs"}
      end
    else
      {:error, "missing checksum.exs file"}
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

  # Write the checksum file with all NIFs available.
  # It receives the module name and checksums.
  @doc false
  def write_checksum!(precompiled_artefacts) do
    file = checksum_file()

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

  defp checksum_file() do
    Path.join(File.cwd!(), "checksum.exs")
  end

  def restore_nif_file(cached_archive, app_priv) do
    Logger.debug("Restore NIF for current node from: #{cached_archive}")
    :erl_tar.extract(cached_archive, [:compressed, {:cwd, app_priv}])
  end

  defp read_map_from_file(file) do
    with {:ok, contents} <- File.read(file),
         {%{} = contents, _} <- Code.eval_string(contents) do
      contents
    else
      _ -> %{}
    end
  end

  def archive_file_url(base_url, file_name) do
    uri = URI.parse(base_url)

    uri =
      Map.update!(uri, :path, fn path ->
        Path.join(path || "", file_name)
      end)

    to_string(uri)
  end

  ## Precompiled archive

  @doc """
  Returns the full path to the precompiled archive.
  """
  def archive_fullpath(config, target) do
    Path.join(cache_dir(), archive_filename(config, target))
  end

  defp archive_filename(config, target) do
    "#{config[:app]}-nif-#{:erlang.system_info(:nif_version)}-#{target}-#{config[:version]}.tar.gz"
  end

  @doc """
  Creates the precompiled archive.
  """
  def create_precompiled_archive(config, target, paths) do
    app_priv = Path.join(Mix.Project.app_path(config), "priv")
    File.mkdir_p!(app_priv)

    cache_dir = cache_dir()
    File.mkdir_p!(cache_dir)

    archive_filename = archive_filename(config, target)
    archive_full_path = Path.expand(Path.join(cache_dir, archive_filename))

    Logger.debug("Creating precompiled archive: #{archive_full_path}")
    Logger.debug("Paths to archive from priv directory: #{inspect(paths)}")

    :ok =
      File.cd!(app_priv, fn ->
        filepaths =
          for path <- paths,
              entry <- Path.wildcard(path),
              do: String.to_charlist(entry)

        :erl_tar.create(archive_full_path, filepaths, [:compressed])
      end)

    {:ok, algo, checksum} = compute_checksum(archive_full_path, checksum_algo())
    {archive_filename, algo, checksum}
  end

  ## NIF URLs

  def available_nif_urls(config, precompiler) do
    targets = precompiler.all_supported_targets(:fetch)

    url_template =
      config[:make_precompiled_url] ||
        Mix.raise("`make_precompiled_url` is not specified in `project`")

    Enum.map(targets, fn target ->
      archive_filename = archive_filename(config, target)
      {target, String.replace(url_template, "@{artefact_filename}", archive_filename)}
    end)
  end

  def current_target_nif_url(config, precompiler) do
    case precompiler.current_target() do
      {:ok, current_target} ->
        available_urls = available_nif_urls(config, precompiler)

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
  @certificate_locations [
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
  ]

  defp certificate_store do
    [
      System.get_env("ELIXIR_MAKE_CACERT"),
      Application.spec(:castore, :vsn) && Application.app_dir(:castore, "priv/cacerts.pem"),
      Application.spec(:certifi, :vsn) && Application.app_dir(:certifi, "priv/cacerts.pem")
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(@certificate_locations)
    |> Enum.find(&File.exists?/1)
    |> warning_if_no_cacertfile!()
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
