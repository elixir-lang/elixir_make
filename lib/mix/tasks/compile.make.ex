defmodule Mix.Tasks.Compile.ElixirMake do
  use Mix.Task

  @recursive true

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
      on Windows, `"gmake"` on FreeBSD and OpenBSD, and `"make"` on everything
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
      setup; the function should return a map of binary to binary.

    * `:make_error_message` - (binary or `:default`) it's a custom error message
      that can be used to give instructions as of how to fix the error (e.g., it
      can be used to suggest installing `gcc` if you're compiling a C
      dependency).

    * `:make_args` - (list of binaries) it's a list of extra arguments to be
      passed.

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
  [Visual C++ Build Tools](http://landinghub.visualstudio.com/visual-cpp-build-tools)
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
  """

  @spec run(OptionParser.argv()) :: :ok | no_return
  def run(args) do
    config = Mix.Project.config()
    Mix.shell().print_app()
    build(config, args)
    Mix.Project.build_structure()
    :ok
  end

  # This is called by Elixir when `mix clean` is run and `:elixir_make` is in
  # the list of compilers.
  def clean() do
    config = Mix.Project.config()
    {clean_targets, config} = Keyword.pop(config, :make_clean)

    if clean_targets do
      config
      |> Keyword.put(:make_targets, clean_targets)
      |> build([])
    end
  end

  defp build(config, task_args) do
    exec =
      System.get_env("MAKE") ||
        os_specific_executable(Keyword.get(config, :make_executable, :default))

    makefile = Keyword.get(config, :make_makefile, :default)
    targets = Keyword.get(config, :make_targets, [])
    env = Keyword.get(config, :make_env, %{})
    env = if is_function(env), do: env.(), else: env
    # In OTP 19, Erlang's `open_port/2` ignores the current working
    # directory when expanding relative paths. This means that `:make_cwd`
    # must be an absolute path. This is a different behaviour from earlier
    # OTP versions and appears to be a bug. It is being tracked at
    # http://bugs.erlang.org/browse/ERL-175.
    cwd = Keyword.get(config, :make_cwd, ".") |> Path.expand(File.cwd!())
    error_msg = Keyword.get(config, :make_error_message, :default) |> os_specific_error_msg()
    custom_args = Keyword.get(config, :make_args, [])
    args = args_for_makefile(exec, makefile) ++ targets ++ custom_args

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
        "nmake"

      {:unix, type} when type in [:freebsd, :openbsd] ->
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
end
