defmodule Mix.Tasks.ElixirMake.FennecPrecompile do
  @moduledoc """
  Precompile with `:fennec_precompile`
  """

  require Logger
  alias FennecPrecompile.Config
  use FennecPrecompile.Precompiler
  @behaviour Mix.Tasks.ElixirMake.Precompile

  @crosscompiler :zig
  @available_nif_versions ~w(2.14 2.15 2.16)

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
    cache_dir = ElixirMake.Artefact.cache_dir()

    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]
    nif_version = ElixirMake.Compile.current_nif_version()

    precompiled_artefacts =
      do_precompile(app, version, nif_version, args, targets, saved_cwd, cache_dir)

    with {:ok, target} <- FennecPrecompile.SystemInfo.target(@crosscompiler) do
      tar_filename = ElixirMake.Artefact.archive_filename(app, version, nif_version, target)
      cached_tar_gz = Path.join([cache_dir, tar_filename])
      ElixirMake.Artefact.restore_nif_file(cached_tar_gz, app)
    end

    Mix.Project.build_structure()
    {:ok, precompiled_artefacts}
  end

  @impl Mix.Tasks.ElixirMake.Precompile
  def build_native(args) do
    if always_use_zig?() do
      build_native_using_zig(args)
    else
      ElixirMake.Compile.compile(args)
    end
  end

  @user_config Application.compile_env(:fennec_precompile, :config, [])
  @impl Mix.Tasks.ElixirMake.Precompile
  def precompiler_context(_args) do
    config = Mix.Project.config()
    app = config[:app]

    config
    |> Keyword.merge(Keyword.get(@user_config, app, []), fn _key, _mix, user_config ->
      user_config
    end)
    |> FennecPrecompile.Config.new()
  end

  @impl Mix.Tasks.ElixirMake.Precompile
  def download_or_reuse_nif_file(%Config{} = config) do
    Logger.debug("Download/Reuse: #{inspect(config)}")
    cache_dir = ElixirMake.Artefact.cache_dir()

    with {:ok, target} <- FennecPrecompile.SystemInfo.target(config.targets) do
      app = config.app

      tar_filename =
        ElixirMake.Artefact.archive_filename(app, config.version, config.nif_version, target)

      app_priv = ElixirMake.Artefact.app_priv(app)
      cached_tar_gz = Path.join([cache_dir, tar_filename])

      if !File.exists?(cached_tar_gz) do
        with :ok <- File.mkdir_p(cache_dir),
             {:ok, tar_gz} <-
               ElixirMake.Artefact.download_archived_artefact(config.base_url, tar_filename),
             :ok <- File.write(cached_tar_gz, tar_gz) do
          Logger.debug("NIF cached at #{cached_tar_gz} and extracted to #{app_priv}")
        end
      end

      with {:file_exists, true} <- {:file_exists, File.exists?(cached_tar_gz)},
           {:file_integrity, :ok} <-
             {:file_integrity, ElixirMake.Artefact.check_file_integrity(cached_tar_gz, app)},
           {:restore_nif, true} <-
             {:restore_nif, ElixirMake.Artefact.restore_nif_file(cached_tar_gz, app)} do
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

  @impl Mix.Tasks.ElixirMake.Precompile
  def available_nif_urls() do
    app = Mix.Project.config()[:app]
    metadata = ElixirMake.Artefact.metadata(app)

    case metadata do
      %{targets: targets, base_url: base_url, version: version} ->
        for target_triple <- targets, nif_version <- @available_nif_versions do
          archive_filename =
            ElixirMake.Artefact.archive_filename(app, version, nif_version, target_triple)

          ElixirMake.Artefact.archive_file_url(base_url, archive_filename)
        end

      _ ->
        raise "metadata about current target for the app #{inspect(app)} is not available. " <>
                "Please compile the project again with: `mix elixir_make.precompile`"
    end
  end

  @impl Mix.Tasks.ElixirMake.Precompile
  def current_target_nif_url() do
    app = Mix.Project.config()[:app]
    metadata = ElixirMake.Artefact.metadata(app)
    nif_version = ElixirMake.Compile.current_nif_version()

    case metadata do
      %{base_url: base_url, target: target, version: version} ->
        archive_filename = ElixirMake.Artefact.archive_filename(app, version, nif_version, target)
        ElixirMake.Artefact.archive_file_url(base_url, archive_filename)

      _ ->
        raise "metadata about current target for the app #{inspect(app)} is not available. " <>
                "Please compile the project again with: `mix FennecPrecompile.precompile`"
    end
  end

  defp build_with_targets(args, targets, post_clean) do
    saved_cwd = File.cwd!()
    cache_dir = System.get_env("ELIXIR_MAKE_CACHE_DIR", ElixirMake.Artefact.cache_dir())

    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]
    nif_version = ElixirMake.Compile.current_nif_version()
    do_precompile(app, version, nif_version, args, targets, saved_cwd, cache_dir)

    if post_clean do
      ElixirMake.Artefact.make_priv_dir(app, :clean)
    else
      with {:ok, target} <- FennecPrecompile.SystemInfo.target(targets) do
        tar_filename = ElixirMake.Artefact.archive_filename(app, version, nif_version, target)
        cached_tar_gz = Path.join([cache_dir, tar_filename])
        ElixirMake.Artefact.restore_nif_file(cached_tar_gz, app)
      end
    end

    Mix.Project.build_structure()
    @return
  end

  defp build_native_using_zig(args) do
    with {:ok, target} <- FennecPrecompile.SystemInfo.target(@crosscompiler) do
      build_with_targets(args, [target], false)
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

  defp do_precompile(app, version, nif_version, args, targets, saved_cwd, cache_dir) do
    saved_cc = System.get_env("CC") || ""
    saved_cxx = System.get_env("CXX") || ""
    saved_cpp = System.get_env("CPP") || ""

    precompiled_artefacts = precompile(app, version, nif_version, args, targets, cache_dir)
    ElixirMake.Artefact.write_checksum!(app, precompiled_artefacts)

    File.cd!(saved_cwd)
    System.put_env("CC", saved_cc)
    System.put_env("CXX", saved_cxx)
    System.put_env("CPP", saved_cpp)
    precompiled_artefacts
  end

  defp precompile(app, version, nif_version, args, targets, cache_dir) do
    Enum.reduce(targets, [], fn target, checksums ->
      Logger.debug("Current compiling target: #{target}")
      ElixirMake.Artefact.make_priv_dir(app, :clean)

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
      ElixirMake.Compile.compile(args)

      {_archive_full_path, archive_tar_gz, checksum_algo, checksum} =
        ElixirMake.Artefact.create_precompiled_archive(
          app,
          version,
          nif_version,
          target,
          cache_dir
        )

      [
        {target, %{path: archive_tar_gz, checksum_algo: checksum_algo, checksum: checksum}}
        | checksums
      ]
    end)
  end

  def write_metadata_to_file(%Config{} = config) do
    app = config.app
    version = config.version
    nif_version = config.nif_version
    cache_dir = FennecPrecompile.SystemInfo.cache_dir()

    with {:ok, target} <- FennecPrecompile.SystemInfo.target(@crosscompiler) do
      archived_artefact_file =
        ElixirMake.Artefact.archive_filename(app, version, nif_version, target)

      metadata = %{
        app: app,
        cached_tar_gz: Path.join([cache_dir, archived_artefact_file]),
        base_url: config.base_url,
        target: target,
        targets: config.targets,
        version: version
      }

      ElixirMake.Artefact.write_metadata(app, metadata)
    end

    :ok
  end
end
