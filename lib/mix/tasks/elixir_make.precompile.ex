defmodule Mix.Tasks.ElixirMake.Precompile do
  @moduledoc """
  Precompile
  """

  @mac_error_msg """
  You need to have gcc and make installed. Try running the
  commands "gcc --version" and / or "make --version". If these programs
  are not installed, you will be prompted to install them.
  """

  @unix_error_msg """
  You need to have gcc and make installed. If you are using
  Ubuntu or any other Debian-based system, install the packages
  "build-essential". Also install "erlang-dev" package if not
  included in your Erlang/OTP version. If you're on Fedora, run
  "dnf group install 'Development Tools'".
  """

  @windows_error_msg ~S"""
  One option is to install a recent version of
  [Visual C++ Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/)
  either manually or using [Chocolatey](https://chocolatey.org/) -
  `choco install VisualCppBuildTools`.

  After installing Visual C++ Build Tools, look in the "Program Files (x86)"
  directory and search for "Microsoft Visual Studio". Note down the full path
  of the folder with the highest version number. Open the "run" command and
  type in the following command (make sure that the path and version number
  are correct):

      cmd /K "C:\Program Files (x86)\Microsoft Visual Studio 14.0\VC\vcvarsall.bat" amd64

  This should open up a command prompt with the necessary environment variables
  set, and from which you will be able to run the "mix compile", "mix deps.compile",
  and "mix test" commands.

  Another option is to install the Linux compatiblity tools from [MSYS2](https://www.msys2.org/).

  After installation start the msys64 bit terminal from the start menu and install the
  C/C++ compiler toolchain. E.g.:

    pacman -S --noconfirm pacman-mirrors pkg-config
    pacman -S --noconfirm --needed base-devel autoconf automake make libtool git \
      mingw-w64-x86_64-toolchain mingw-w64-x86_64-openssl mingw-w64-x86_64-libtool

  This will give you a compilation suite nearly compatible with Unix' standard tools.
  """

  require Logger
  alias FennecPrecompile.Config
  use FennecPrecompile.Precompiler

  @crosscompiler :zig
  @available_nif_versions ~w(2.14 2.15 2.16)

  @recursive true

  @return if Version.match?(System.version(), "~> 1.9"), do: {:ok, []}, else: :ok

  @impl FennecPrecompile.Precompiler
  def all_supported_targets() do
    FennecPrecompile.SystemInfo.default_targets(@crosscompiler)
  end

  @impl FennecPrecompile.Precompiler
  def current_target() do
    FennecPrecompile.SystemInfo.target(@crosscompiler)
  end

  @impl FennecPrecompile.Precompiler
  def precompile(args, targets) do
    saved_cwd = File.cwd!()
    cache_dir = System.get_env("ELIXIR_MAKE_CACHE_DIR", FennecPrecompile.SystemInfo.cache_dir())

    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]
    precompiled_artefacts = do_precompile(app, version, args, targets, saved_cwd, cache_dir)
    with {:ok, target} <- FennecPrecompile.SystemInfo.target(@crosscompiler) do
      nif_version = "#{:erlang.system_info(:nif_version)}"
      tar_filename = archive_filename(app, version, nif_version, target)
      cached_tar_gz = Path.join([cache_dir, tar_filename])
      restore_nif_file(cached_tar_gz, app)
    end
    Mix.Project.build_structure()
    {:ok, precompiled_artefacts}
  end

  @spec elixir_make_run(OptionParser.argv()) :: :ok | no_return
  def elixir_make_run(args) do
    config = Mix.Project.config()
    Mix.shell().print_app()
    priv? = File.dir?("priv")
    Mix.Project.ensure_structure()
    build(config, args)

    # IF there was no priv before and now there is one, we assume
    # the user wants to copy it. If priv already existed and was
    # written to it, then it won't be copied if build_embedded is
    # set to true.
    if not priv? and File.dir?("priv") do
      Mix.Project.build_structure()
    end

    @return
  end

  def build_with_targets(args, targets, post_clean) do
    saved_cwd = File.cwd!()
    cache_dir = System.get_env("ELIXIR_MAKE_CACHE_DIR", FennecPrecompile.SystemInfo.cache_dir())

    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]
    do_precompile(app, version, args, targets, saved_cwd, cache_dir)
    if post_clean do
      make_priv_dir(app, :clean)
    else
      with {:ok, target} <- FennecPrecompile.SystemInfo.target(targets) do
        nif_version = FennecPrecompile.SystemInfo.current_nif_version()
        tar_filename = archive_filename(app, version, nif_version, target)
        cached_tar_gz = Path.join([cache_dir, tar_filename])
        restore_nif_file(cached_tar_gz, app)
      end
    end
    Mix.Project.build_structure()
    @return
  end

  def build_native_using_zig(args) do
    with {:ok, target} <- FennecPrecompile.SystemInfo.target(@crosscompiler) do
      build_with_targets(args, [target], false)
    end
  end

  def build_native(args) do
    if always_use_zig?() do
      build_native_using_zig(args)
    else
      elixir_make_run(args)
    end
  end

  defp always_use_zig?() do
    always_use_zig?(System.get_env("FENNEC_PRECOMPILE_ALWAYS_USE_ZIG", "NO"))
  end

  defp always_use_zig?("true"), do: true
  defp always_use_zig?("TRUE"), do: true
  defp always_use_zig?("YES"), do: true
  defp always_use_zig?("yes"), do: true
  defp always_use_zig?("y"), do: true
  defp always_use_zig?("on"), do: true
  defp always_use_zig?("ON"), do: true
  defp always_use_zig?(_), do: false

  defp do_precompile(app, version, args, targets, saved_cwd, cache_dir) do
    saved_cc = System.get_env("CC") || ""
    saved_cxx = System.get_env("CXX") || ""
    saved_cpp = System.get_env("CPP") || ""

    precompiled_artefacts = precompile(app, version, args, targets, cache_dir)
    write_checksum!(app, precompiled_artefacts)

    File.cd!(saved_cwd)
    System.put_env("CC", saved_cc)
    System.put_env("CXX", saved_cxx)
    System.put_env("CPP", saved_cpp)
    precompiled_artefacts
  end

  defp precompile(app, version, args, targets, cache_dir) do
    Enum.reduce(targets, [], fn target, checksums ->
      Logger.debug("Current compiling target: #{target}")
      make_priv_dir(app, :clean)
      {cc, cxx} =
        case {:os.type(), target} do
          {{:unix, :darwin}, "x86_64-macos" <> _} ->
            {"gcc -arch x86_64", "g++ -arch x86_64"}
          {{:unix, :darwin}, "aarch64-macos" <> _} ->
            {"gcc -arch arm64", "g++ -arch arm64"}
          _ ->
            {"zig cc -target #{target}", "zig c++ -target #{target}"}
        end
      System.put_env("CC", cc)
      System.put_env("CXX", cxx)
      System.put_env("CPP", cxx)
      elixir_make_run(args)

      {archive_full_path, archive_tar_gz} = create_precompiled_archive(app, version, target, cache_dir)
      {:ok, algo, checksum} = compute_checksum(archive_full_path, :sha256)
      [{target, %{path: archive_tar_gz, checksum_algo: algo, checksum: checksum}} | checksums]
    end)
  end

  defp create_precompiled_archive(app, version, target, cache_dir) do
    saved_cwd = File.cwd!()

    app_priv = app_priv(app)
    File.cd!(app_priv)
    nif_version = FennecPrecompile.SystemInfo.current_nif_version()

    archive_tar_gz = archive_filename(app, version, nif_version, target)
    archive_full_path = Path.expand(Path.join([cache_dir, archive_tar_gz]))
    File.mkdir_p!(cache_dir)
    Logger.debug("Creating precompiled archive: #{archive_full_path}")

    filelist = build_file_list_at(app_priv)
    File.cd!(app_priv)
    :ok = :erl_tar.create(archive_full_path, filelist, [:compressed])

    File.cd!(saved_cwd)
    {archive_full_path, archive_tar_gz}
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
              {filelist, visited} = build_file_list_at(Path.join([dir, folder_path]), visited, files_in_folder)
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

  defp make_priv_dir(app, :clean) when is_atom(app) do
    app_priv = app_priv(app)
    File.rm_rf!(app_priv)
    make_priv_dir(app)
  end

  defp make_priv_dir(app) when is_atom(app) do
    File.mkdir_p!(app_priv(app))
  end

  @checksum_algo :sha256
  @checksum_algorithms [@checksum_algo]

  def write_metadata_to_file(%Config{} = config) do
    app = config.app
    version = config.version
    nif_version = config.nif_version
    cache_dir = System.get_env("ELIXIR_MAKE_CACHE_DIR", FennecPrecompile.SystemInfo.cache_dir())

    with {:ok, target} <- FennecPrecompile.SystemInfo.target(@crosscompiler) do
      archived_artefact_file = archive_filename(app, version, nif_version, target)
      metadata = %{
        app: app,
        cached_tar_gz: Path.join([cache_dir, archived_artefact_file]),
        base_url: config.base_url,
        target: target,
        targets: config.targets,
        version: version
      }

      write_metadata(app, metadata)
    end
    :ok
  end

  def archive_filename(app, version, nif_version, target) do
    "#{app}-nif-#{nif_version}-#{target}-#{version}.tar.gz"
  end

  def download_or_reuse_nif_file(%Config{} = config) do
    Logger.debug("Download/Reuse: #{inspect(config)}")
    cache_dir = System.get_env("ELIXIR_MAKE_CACHE_DIR", FennecPrecompile.SystemInfo.cache_dir())

    with {:ok, target} <- FennecPrecompile.SystemInfo.target(config.targets) do
      app = config.app
      tar_filename = archive_filename(app, config.version, config.nif_version, target)
      cached_tar_gz = Path.join([cache_dir, tar_filename])

      if !File.exists?(cached_tar_gz) do
        with :ok <- File.mkdir_p(cache_dir),
             {:ok, tar_gz} <- download_tar_gz(config.base_url, tar_filename),
             :ok <- File.write(cached_tar_gz, tar_gz) do
            Logger.debug("NIF cached at #{cached_tar_gz} and extracted to #{app_priv(app)}")
        end
      end

      with {:file_exists, true} <- {:file_exists, File.exists?(cached_tar_gz)},
           {:file_integrity, :ok} <- {:file_integrity, check_file_integrity(cached_tar_gz, app)},
           {:restore_nif, true} <- {:restore_nif, restore_nif_file(cached_tar_gz, app)} do
            :ok
      else
        {:file_exists, _} ->
          {:error, "Cache file not exists or cannot download"}
        {:file_integrity, _} ->
          {:error, "Cache file integrity check failed"}
        {:restore_nif, status} ->
          {:error, "Cannot restore nif from cache: #{inspect(status)}"}
      end
    end
  end

  def restore_nif_file(cached_tar_gz, app) do
    Logger.debug("Restore NIF for current node from: #{cached_tar_gz}")
    :erl_tar.extract(cached_tar_gz, [:compressed, {:cwd, to_string(app_priv(app))}])
  end

  @doc """
  Returns URLs for NIFs based on its module name.
  The module name is the one that defined the NIF and this information
  is stored in a metadata file.
  """
  def available_nif_urls(app) when is_atom(app) do
    metadata =
      app
      |> metadata_file()
      |> read_map_from_file()

    case metadata do
      %{targets: targets, base_url: base_url, version: version} ->
        for target_triple <- targets, nif_version <- @available_nif_versions do
          target = "#{to_string(app)}-nif-#{nif_version}-#{target_triple}-#{version}"

          tar_gz_file_url(base_url, target)
        end

      _ ->
        raise "metadata about current target for the app #{inspect(app)} is not available. " <>
                "Please compile the project again with: `mix elixir_make.precompile`"
    end
  end

  @doc """
  Returns the file URL to be downloaded for current target.
  It receives the NIF module.
  """
  def current_target_nif_url(app) do
    metadata =
      app
      |> metadata_file()
      |> read_map_from_file()

    nif_version = "#{:erlang.system_info(:nif_version)}"
    case metadata do
      %{base_url: base_url, target: target, version: version} ->
        target = "#{to_string(app)}-nif-#{nif_version}-#{target}-#{version}"
        tar_gz_file_url(base_url, target)

      _ ->
        raise "metadata about current target for the app #{inspect(app)} is not available. " <>
                "Please compile the project again with: `mix FennecPrecompile.precompile`"
    end
  end

  defp tar_gz_file_url(base_url, file_name) do
    uri = URI.parse(base_url)

    uri =
      Map.update!(uri, :path, fn path ->
        Path.join(path || "", "#{file_name}.tar.gz")
      end)

    to_string(uri)
  end

  defp read_map_from_file(file) do
    with {:ok, contents} <- File.read(file),
         {%{} = contents, _} <- Code.eval_string(contents) do
      contents
    else
      _ -> %{}
    end
  end

  defp write_metadata(app, metadata) do
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
    System.get_env("ELIXIR_MAKE_CACHE_DIR", FennecPrecompile.SystemInfo.cache_dir())
    |> Path.join("metadata")
    |> Path.join("metadata-#{app}.exs")
  end

  defp download_tar_gz(base_url, tar_filename) do
    "#{base_url}/#{tar_filename}"
    |> download_nif_artifact()
  end

  defp download_nif_artifact(url) do
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

  # Download a list of files from URLs and calculate its checksum.
  # Returns a list with details of the download and the checksum of each file.
  @doc false
  def download_nif_artifacts_with_checksums!(urls, options \\ []) do
    ignore_unavailable? = Keyword.get(options, :ignore_unavailable, false)

    tasks =
      Task.async_stream(urls, fn url -> {url, download_nif_artifact(url)} end, timeout: :infinity)

    cache_dir = FennecPrecompile.SystemInfo.cache_dir()

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

  defp check_file_integrity(file_path, app) when is_atom(app) do
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

  defp compute_checksum(file_path, algo) do
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

  defp compare_checksum(file_path, algo, expected_checksum) do
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

  # Write the checksum file with all NIFs available.
  # It receives the module name and checksums.
  @doc false
  def write_checksum!(app, precompiled_artefacts) do
    file = checksum_file(app)

    pairs =
      for {_target, %{path: path, checksum: checksum, checksum_algo: algo}} <- precompiled_artefacts, into: %{} do
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

  def build(config, task_args) do
    exec =
      System.get_env("MAKE") ||
        os_specific_executable(Keyword.get(config, :make_executable, :default))

    makefile = Keyword.get(config, :make_makefile, :default)
    targets = Keyword.get(config, :make_targets, [])
    env = Keyword.get(config, :make_env, %{})
    env = if is_function(env), do: env.(), else: env
    env = default_env(config, env)

    # In OTP 19, Erlang's `open_port/2` ignores the current working
    # directory when expanding relative paths. This means that `:make_cwd`
    # must be an absolute path. This is a different behaviour from earlier
    # OTP versions and appears to be a bug. It is being tracked at
    # https://bugs.erlang.org/browse/ERL-175.
    cwd = Keyword.get(config, :make_cwd, ".") |> Path.expand(File.cwd!())
    error_msg = Keyword.get(config, :make_error_message, :default) |> os_specific_error_msg()
    custom_args = Keyword.get(config, :make_args, [])

    if String.contains?(cwd, " ") do
      IO.warn(
        "the absolute path to the makefile for this project contains spaces. Make might " <>
          "not work properly if spaces are present in the path. The absolute path is: " <>
          inspect(cwd)
      )
    end

    base = exec |> Path.basename() |> Path.rootname()
    args = args_for_makefile(base, makefile) ++ targets ++ custom_args

    case cmd(exec, args, cwd, env, "--verbose" in task_args) do
      0 ->
        :ok

      exit_status ->
        raise_build_error(exec, exit_status, error_msg)
    end
  end

  # Runs `exec [args]` in `cwd` and prints the stdout and stderr in real time,
  # as soon as `exec` prints them (using `IO.Stream`).
  defp cmd(exec, args, cwd, env, verbose?) do
    opts = [
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true,
      cd: cwd,
      env: env
    ]

    if verbose? do
      print_verbose_info(exec, args)
    end

    {%IO.Stream{}, status} = System.cmd(find_executable(exec), args, opts)
    status
  end

  defp find_executable(exec) do
    System.find_executable(exec) ||
      Mix.raise("""
      "#{exec}" not found in the path. If you have set the MAKE environment variable,
      please make sure it is correct.
      """)
  end

  defp raise_build_error(exec, exit_status, error_msg) do
    Mix.raise(~s{Could not compile with "#{exec}" (exit status: #{exit_status}).\n} <> error_msg)
  end

  defp os_specific_executable(exec) when is_binary(exec) do
    exec
  end

  defp os_specific_executable(:default) do
    case :os.type() do
      {:win32, _} ->
        cond do
          System.find_executable("nmake") -> "nmake"
          System.find_executable("make") -> "make"
          true -> "nmake"
        end

      {:unix, type} when type in [:freebsd, :openbsd, :netbsd] ->
        "gmake"

      _ ->
        "make"
    end
  end

  defp os_specific_error_msg(msg) when is_binary(msg) do
    msg
  end

  defp os_specific_error_msg(:default) do
    case :os.type() do
      {:unix, :darwin} -> @mac_error_msg
      {:unix, _} -> @unix_error_msg
      {:win32, _} -> @windows_error_msg
      _ -> ""
    end
  end

  # Returns a list of command-line args to pass to make (or nmake/gmake) in
  # order to specify the makefile to use.
  defp args_for_makefile("nmake", :default), do: ["/F", "Makefile.win"]
  defp args_for_makefile("nmake", makefile), do: ["/F", makefile]
  defp args_for_makefile(_, :default), do: []
  defp args_for_makefile(_, makefile), do: ["-f", makefile]

  defp print_verbose_info(exec, args) do
    args =
      Enum.map_join(args, " ", fn arg ->
        if String.contains?(arg, " "), do: inspect(arg), else: arg
      end)

    Mix.shell().info("Compiling with make: #{exec} #{args}")
  end

  # Returns a map of default environment variables
  # Defaults may be overwritten.
  defp default_env(config, default_env) do
    root_dir = :code.root_dir()
    erl_interface_dir = Path.join(root_dir, "usr")
    erts_dir = Path.join(root_dir, "erts-#{:erlang.system_info(:version)}")
    erts_include_dir = Path.join(erts_dir, "include")
    erl_ei_lib_dir = Path.join(erl_interface_dir, "lib")
    erl_ei_include_dir = Path.join(erl_interface_dir, "include")

    Map.merge(
      %{
        # Don't use Mix.target/0 here for backwards compatibility
        "MIX_TARGET" => env("MIX_TARGET", "host"),
        "MIX_ENV" => to_string(Mix.env()),
        "MIX_BUILD_PATH" => Mix.Project.build_path(config),
        "MIX_APP_PATH" => Mix.Project.app_path(config),
        "MIX_COMPILE_PATH" => Mix.Project.compile_path(config),
        "MIX_CONSOLIDATION_PATH" => Mix.Project.consolidation_path(config),
        "MIX_DEPS_PATH" => Mix.Project.deps_path(config),
        "MIX_MANIFEST_PATH" => Mix.Project.manifest_path(config),

        # Rebar naming
        "ERL_EI_LIBDIR" => env("ERL_EI_LIBDIR", erl_ei_lib_dir),
        "ERL_EI_INCLUDE_DIR" => env("ERL_EI_INCLUDE_DIR", erl_ei_include_dir),

        # erlang.mk naming
        "ERTS_INCLUDE_DIR" => env("ERTS_INCLUDE_DIR", erts_include_dir),
        "ERL_INTERFACE_LIB_DIR" => env("ERL_INTERFACE_LIB_DIR", erl_ei_lib_dir),
        "ERL_INTERFACE_INCLUDE_DIR" => env("ERL_INTERFACE_INCLUDE_DIR", erl_ei_include_dir),

        # Disable default erlang values
        "BINDIR" => nil,
        "ROOTDIR" => nil,
        "PROGNAME" => nil,
        "EMU" => nil
      },
      default_env
    )
  end

  defp env(var, default) do
    System.get_env(var) || default
  end
end
