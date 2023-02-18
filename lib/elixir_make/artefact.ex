defmodule ElixirMake.Artefact do
  @moduledoc false

  require Logger
  alias ElixirMake.Artefact

  @checksum_algo :sha256
  defstruct [:basename, :checksum, :checksum_algo]

  @doc """
  Returns user cache directory.
  """
  def cache_dir() do
    cache_opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}

    cache_dir =
      Path.expand(
        System.get_env("ELIXIR_MAKE_CACHE_DIR") ||
          :filename.basedir(:user_cache, "", cache_opts)
      )

    File.mkdir_p!(cache_dir)
    cache_dir
  end

  @doc """
  Computes the checksum and artefact for the given contents.
  """
  def checksum(basename, contents) do
    hash = :crypto.hash(@checksum_algo, contents)
    checksum = Base.encode16(hash, case: :lower)
    %Artefact{basename: basename, checksum: checksum, checksum_algo: @checksum_algo}
  end

  @doc """
  Writes checksums to disk.
  """
  def write_checksums!(checksums) do
    file = checksum_file()

    pairs =
      Enum.map(checksums, fn
        %Artefact{basename: basename, checksum: checksum, checksum_algo: algo} ->
          {basename, "#{algo}:#{checksum}"}
      end)

    lines =
      for {filename, checksum} <- Enum.sort(pairs) do
        ~s(  "#{filename}" => "#{checksum}",\n)
      end

    File.write!(file, ["%{\n", lines, "}\n"])
  end

  defp checksum_file() do
    Path.join(File.cwd!(), "checksum.exs")
  end

  ## Archive handling

  @doc """
  Returns the full path to the precompiled archive.
  """
  def archive_path(config, target, nif_version) do
    Path.join(cache_dir(), archive_filename(config, target, nif_version))
  end

  defp archive_filename(config, target, nif_version) do
    case config[:make_precompiler] do
      {:nif, _} ->
        "#{config[:app]}-nif-#{nif_version}-#{target}-#{config[:version]}.tar.gz"

      {type, _} ->
        "#{config[:app]}-#{type}-#{target}-#{config[:version]}.tar.gz"
    end
  end

  @doc """
  Compresses the given files and computes its checksum and artefact.
  """
  def compress(archive_path, paths) do
    :ok = :erl_tar.create(archive_path, paths, [:compressed])
    checksum(Path.basename(archive_path), File.read!(archive_path))
  end

  @doc """
  Verifies and decompresses the given `archive_path` at `app_priv`.
  """
  def verify_and_decompress(archive_path, app_priv) do
    basename = Path.basename(archive_path)

    case File.read(archive_path) do
      {:ok, contents} ->
        verify_and_decompress(basename, archive_path, contents, app_priv)

      {:error, reason} ->
        {:error,
         "precompiled #{inspect(basename)} does not exist or cannot download: #{inspect(reason)}"}
    end
  end

  defp verify_and_decompress(basename, archive_path, contents, app_priv) do
    checksum_file()
    |> read_map_from_file()
    |> case do
      %{^basename => algo_with_checksum} ->
        [algo, checksum] = String.split(algo_with_checksum, ":")
        algo = String.to_existing_atom(algo)

        case checksum(basename, contents) do
          %Artefact{checksum: ^checksum, checksum_algo: ^algo} ->
            case :erl_tar.extract({:binary, contents}, [:compressed, {:cwd, app_priv}]) do
              :ok ->
                :ok

              {:error, term} ->
                {:error,
                 "cannot decompress precompiled #{inspect(archive_path)}: #{inspect(term)}"}
            end

          _ ->
            {:error, "precompiled #{inspect(basename)} does not match its checksum"}
        end

      checksum when checksum == %{} ->
        {:error, "missing checksum.exs file"}

      _checksum ->
        {:error, "precompiled #{inspect(basename)} does not exist in checksum.exs"}
    end
  end

  defp read_map_from_file(file) do
    with {:ok, contents} <- File.read(file),
         {%{} = contents, _} <- Code.eval_string(contents) do
      contents
    else
      _ -> %{}
    end
  end

  ## Archive/NIF urls

  @doc """
  Returns all available {{target, nif_version}, url} pairs available.
  """
  def available_target_urls(config, precompiler) do
    targets = precompiler.all_supported_targets(:fetch)

    url_template =
      config[:make_precompiler_url] ||
        Mix.raise("`make_precompiler_url` is not specified in `project`")

    nif_versions =
      config[:make_precompiler_nif_versions] ||
        [versions: ["#{:erlang.system_info(:nif_version)}"]]

    Enum.reduce(targets, [], fn target, archives ->
      archive_filenames =
        Enum.reduce(nif_versions[:versions], [], fn nif_version, acc ->
          availability = nif_versions[:availability]

          available? =
            if is_function(availability, 2) do
              availability.(target, nif_version)
            else
              true
            end

          if available? do
            archive_filename = archive_filename(config, target, nif_version)

            [
              {{target, nif_version},
               String.replace(url_template, "@{artefact_filename}", archive_filename)}
              | acc
            ]
          else
            acc
          end
        end)

      archive_filenames ++ archives
    end)
  end

  @doc """
  Returns the url for the current target.
  """
  def current_target_url(config, precompiler, nif_version) do
    case precompiler.current_target() do
      {:ok, current_target} ->
        available_urls = available_target_urls(config, precompiler)
        target_at_nif_version = {current_target, nif_version}

        case List.keyfind(available_urls, target_at_nif_version, 0) do
          {^target_at_nif_version, download_url} ->
            {:ok, current_target, download_url}

          nil ->
            available_targets = Enum.map(available_urls, fn {target, _url} -> target end)

            {:error,
             {:unavailable_target, current_target,
              "cannot find download url for current target `#{inspect(current_target)}`. Available targets are: #{inspect(available_targets)}"}}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  ## Download

  def download(url) do
    url_charlist = String.to_charlist(url)

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:public_key)

    if proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy") do
      Mix.shell().info("Using HTTP_PROXY: #{proxy}")
      %{host: host, port: port} = URI.parse(proxy)

      :httpc.set_options([{:proxy, {{String.to_charlist(host), port}, []}}])
    end

    if proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") do
      Mix.shell().info("Using HTTPS_PROXY: #{proxy}")
      %{host: host, port: port} = URI.parse(proxy)
      :httpc.set_options([{:https_proxy, {{String.to_charlist(host), port}, []}}])
    end

    # https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/inets
    # TODO: This may no longer be necessary from Erlang/OTP 25.0 or later.
    https_options = [
      ssl:
        [
          verify: :verify_peer,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ cacerts_options()
    ]

    options = [body_format: :binary]

    case :httpc.request(:get, {url_charlist, []}, https_options, options) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      other ->
        {:error, "couldn't fetch NIF from #{url}: #{inspect(other)}"}
    end
  end

  defp cacerts_options do
    cond do
      path = System.get_env("ELIXIR_MAKE_CACERT") ->
        [cacertfile: path]

      Application.spec(:castore, :vsn) ->
        [cacertfile: Application.app_dir(:castore, "priv/cacerts.pem")]

      Application.spec(:certifi, :vsn) ->
        [cacertfile: Application.app_dir(:certifi, "priv/cacerts.pem")]

      certs = otp_cacerts() ->
        [cacerts: certs]

      path = cacerts_from_os() ->
        [cacertfile: path]

      true ->
        warn_no_cacerts()
        []
    end
  end

  defp otp_cacerts do
    if System.otp_release() >= "25" do
      # cacerts_get/0 raises if no certs found
      try do
        :public_key.cacerts_get()
      rescue
        _ ->
          nil
      end
    end
  end

  # https_opts and related code are taken from
  # https://github.com/elixir-cldr/cldr_utils/blob/v2.19.1/lib/cldr/http/http.ex
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

  defp cacerts_from_os do
    Enum.find(@certificate_locations, &File.exists?/1)
  end

  defp warn_no_cacerts do
    Mix.shell().error("""
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

    4. Use OTP 25+ on an OS that has built-in certificate
       trust store.
    """)
  end
end
