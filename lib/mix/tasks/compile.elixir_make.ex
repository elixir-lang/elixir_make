defmodule Mix.Tasks.Compile.ElixirMake do
  @moduledoc """
  Runs `make` in the current project.

  This task runs `make` in the current project; any output coming from `make` is
  printed in real-time on stdout.

  ## Configuration

  This compiler can be configured through the return value of the `project/0`
  function in `mix.exs`; for example:

      def project() do
        [app: :myapp,
         make_executable: "make",
         make_makefile: "Othermakefile",
         compilers: [:elixir_make] ++ Mix.compilers,
         deps: deps()]
      end

  The following options are available:

    * `:make_executable` - (binary or `:default`) it's the executable to use as the
      `make` program. If not provided or if `:default`, it defaults to `"nmake"`
      on Windows, `"gmake"` on FreeBSD, OpenBSD and NetBSD, and `"make"` on everything
      else. You can, for example, customize which executable to use on a
      specific OS and use `:default` for every other OS. If the `MAKE`
      environment variable is present, that is used as the value of this option.

    * `:make_makefile` - (binary or `:default`) it's the Makefile to
      use. Defaults to `"Makefile"` for Unix systems and `"Makefile.win"` for
      Windows systems if not provided or if `:default`.

    * `:make_targets` - (list of binaries) it's the list of Make targets that
      should be run. Defaults to `[]`, meaning `make` will run the first target.

    * `:make_clean` - (list of binaries) it's a list of Make targets to be run
      when `mix clean` is run. It's only run if a non-`nil` value for
      `:make_clean` is provided. Defaults to `nil`.

    * `:make_cwd` - (binary) it's the directory where `make` will be run,
      relative to the root of the project.

    * `:make_env` - (map of binary to binary) it's a map of extra environment
      variables to be passed to `make`. You can also pass a function in here in
      case `make_env` needs access to things that are not available during project
      setup; the function should return a map of binary to binary. Many default
      environment variables are set, see section below

    * `:make_error_message` - (binary or `:default`) it's a custom error message
      that can be used to give instructions as of how to fix the error (e.g., it
      can be used to suggest installing `gcc` if you're compiling a C
      dependency).

    * `:make_args` - (list of binaries) it's a list of extra arguments to be passed.

  The following options configure precompilation:

    * `:make_precompiler` - the precompiled module to use. Defaults to none.

    * `:make_precompiled_url` - the download URL template. Defaults to none.
      Required when `make_precompiler` is set.

    * `:make_nif_filename` - the filename of the compiled NIF without extension.
      Defaults to the app name.

    * `:make_force_build` - if build should be forced even if precompiled artefacts
      are available. Defaults to true if the app has a `-dev` version flag.

  See [the Precompilation guide](PRECOMPILATION_GUIDE.md) for more information.

  ## Default environment variables

  There are also several default environment variables set:

    * `MIX_TARGET`
    * `MIX_ENV`
    * `MIX_BUILD_PATH` - same as `Mix.Project.build_path/0`
    * `MIX_APP_PATH` - same as `Mix.Project.app_path/0`
    * `MIX_COMPILE_PATH` - same as `Mix.Project.compile_path/0`
    * `MIX_CONSOLIDATION_PATH` - same as `Mix.Project.consolidation_path/0`
    * `MIX_DEPS_PATH` - same as `Mix.Project.deps_path/0`
    * `MIX_MANIFEST_PATH` - same as `Mix.Project.manifest_path/0`
    * `ERL_EI_LIBDIR`
    * `ERL_EI_INCLUDE_DIR`
    * `ERTS_INCLUDE_DIR`
    * `ERL_INTERFACE_LIB_DIR`
    * `ERL_INTERFACE_INCLUDE_DIR`

  These may also be overwritten with the `make_env` option.

  ## Compilation artifacts and working with priv directories

  Generally speaking, compilation artifacts are written to the `priv`
  directory, as that the only directory, besides `ebin`, which are
  available to Erlang/OTP applications.

  However, note that Mix projects supports the `:build_embedded`
  configuration, which controls if assets in the `_build` directory
  are symlinked (when `false`, the default) or copied (`true`).
  In order to support both options for `:build_embedded`, it is
  important to follow the given guidelines:

    * The "priv" directory must not exist in the source code
    * The Makefile should copy any artifact to `$MIX_APP_PATH/priv`
      or, even better, to `$MIX_APP_PATH/priv/$MIX_TARGET`
    * If there are static assets, the Makefile should copy them over
      from a directory at the project root (not named "priv")

  """

  use Mix.Task
  alias ElixirMake.{Artefact, Precompiler}

  def run(args) do
    config = Mix.Project.config()
    app = config[:app]
    version = config[:version]
    force_build = pre_release?(version) or Keyword.get(config, :make_force_build, false)
    precompiler = config[:make_precompiler]

    cond do
      precompiler == nil ->
        ElixirMake.Compiler.compile(args)

      force_build == true ->
        precompiler.build_native(args)

      true ->
        nif_filename = config[:make_nif_filename] || "#{app}"
        priv_dir = ElixirMake.Precompiler.app_priv(app)

        load_path =
          case :os.type() do
            {:win32, _} -> Path.join([priv_dir, "#{nif_filename}.dll"])
            _ -> Path.join([priv_dir, "#{nif_filename}.so"])
          end

        with false <- File.exists?(load_path),
             {:error, precomp_error} <- download_or_reuse_nif(precompiler) do
          Mix.shell().error("""
          Error happened while installing #{app} from precompiled binary: #{precomp_error}.

          Attempting to compile #{app} from source...\
          """)

          precompiler.build_native(args)
        else
          _ -> {:ok, []}
        end
    end
  end

  # This is called by Elixir when `mix clean` is run and `:elixir_make` is in
  # the list of compilers.
  @spec clean :: nil | :ok
  def clean() do
    config = Mix.Project.config()
    {clean_targets, config} = Keyword.pop(config, :make_clean)

    if clean_targets do
      config
      |> Keyword.put(:make_targets, clean_targets)
      |> ElixirMake.Compiler.make([])
    end
  end

  defp pre_release?(version) do
    "dev" in Version.parse!(version).pre
  end

  defp download_or_reuse_nif(precompiler) do
    config = Mix.Project.config()
    app = config[:app]

    case Artefact.current_target_nif_url(precompiler) do
      {:ok, target, url} ->
        cache_dir = Precompiler.cache_dir()

        version = config[:version]
        nif_version = Precompiler.current_nif_version()
        archived_filename = Precompiler.archive_filename(app, version, nif_version, target)

        app_priv = Precompiler.app_priv(app)
        archived_fullpath = Path.join([cache_dir, archived_filename])

        with false <- File.exists?(archived_fullpath),
             :ok <- File.mkdir_p(cache_dir),
             {:ok, archived_data} <- Artefact.download_nif_artefact(url),
             :ok <- File.write(archived_fullpath, archived_data) do
          Mix.shell().info("NIF cached at #{archived_fullpath} and extracted to #{app_priv}")
        end

        case File.exists?(archived_fullpath) do
          true ->
            case Artefact.check_file_integrity(archived_fullpath, app) do
              :ok ->
                case Artefact.restore_nif_file(archived_fullpath, app) do
                  :ok ->
                    :ok

                  {:error, term} ->
                    {:error, "cannot restore nif from cache: #{inspect(term)}"}
                end

              {:error, reason} ->
                {:error, "cache file integrity check failed: #{reason}"}
            end

          false ->
            {:error, "precompiled tar file does not exist or cannot download"}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end
end
