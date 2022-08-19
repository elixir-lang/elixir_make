# Precompilation guide

This guide has two sections, the first one is intended for precompiler module developers. It covers a minimal example of creating a precompiler module. The second section is intended for library developers who want their library to be able to use precompiled artefacts in a simple way.

- [Library Developer](#library-developer)
- [Precompiler Module Developer](#precompiler-module-developer)

## Library Developer

This guide assumes you have already added `elixir_make` to your library and you have written a `Makefile` that compiles the native code in your project. Once your native code compile and works as expected, you are now ready to precompile it.

A full demo project is available on [cocoa-xu/cc_precompiler_example](https://github.com/cocoa-xu/cc_precompiler_example).

### Setup mix.exs

To use a precompiler module such as the `CCPrecompiler` example above, we first add the precompiler (`:cc_precompiler` here) and `:elixir_make` to `deps`.

```elixir
def deps do
[
    # ...
    {:elixir_make, "~> 0.6", runtime: false},
    {:cc_precompiler, "~> 0.1.0", runtime: false, github: "cocoa-xu/cc_precompiler"}
    # ...
]
end
```

Then add `:elixir_make` to the `compilers` list, and set `CCPrecompile` as the value for `make_precompiler`.

```elixir
@version "0.1.0"
def project do
  [
    # ...
    compilers: [:elixir_make] ++ Mix.compilers(),
    # elixir_make specific config
    make_precompiler: CCPrecompiler,
    make_precompiled_url: "https://github.com/cocoa-xu/cc_precompiler_example/releases/download/v#{@version}/@{artefact_filename}",
    make_nif_filename: "nif",
    # ...
  ]
end
```

Another required field is `make_precompiled_url`. It is a URL template to the artefact file.

`@{artefact_filename}` in the URL template string will be replaced by corresponding artefact filenames when fetching them. For example, `cc_precompiler_example-nif-2.16-x86_64-linux-gnu-0.1.0.tar.gz`.

Note that there is an optional config key for elixir_make, `make_nif_filename`. If the name (file extension does not count) of the shared library is different from your app's name, then `make_nif_filename` should be set. For example, if the app name is `"cc_precompiler_example"` while the name shared library is `"nif.so"` (or `"nif.dll"` on windows), then `make_nif_filename` should be set as `"nif"`.

### (Optional) Test the NIF code locally

To test the NIF code locally, you can either set `force_build` to `true` or append `"-dev"` to your NIF library's version string.

```elixir
@version "0.1.0-dev"

def project do
  [
    # either append `"-dev"` to your NIF library's version string
    version: @version,
    # or set force_build to true
    force_build: true,
    # ...
  ]
end
```

Doing so will ask `elixir_make` to only compile for the current host instead of building for all available targets.

```shell
$ mix compile
cc -shared -std=c11 -O3 -fPIC -I"/usr/local/lib/erlang/erts-13.0.3/include" -undefined dynamic_lookup -flat_namespace -undefined suppress "/Users/cocoa/git/cc_precompiler_example/c_src/cc_precompiler_example.c" -o "/Users/cocoa/Git/cc_precompiler_example/_build/dev/lib/cc_precompiler_example/priv/nif.so"
$ mix test
make: Nothing to be done for `build'.
Generated cc_precompiler_example app
.

Finished in 0.00 seconds (0.00s async, 0.00s sync)
1 test, 0 failures

Randomized with seed 102464
```

### Precompile for available targets

It's possible to either setup a CI task to do the precompilation job or precompile on a local machine and upload the precompiled artefacts.

To precompile for all targets on a local machine:

```shell
MIX_ENV=prod mix elixir_make.precompile
```

Environment variable `ELIXIR_MAKE_CACHE_DIR` can be used to set the cache dir for the precompiled artefacts, for instance, to output precompiled artefacts in the cache directory of the current working directory, `export ELIXIR_MAKE_CACHE_DIR="$(pwd)/cache"`.

To setup a CI task such as GitHub Actions, the following workflow file can be used for reference:

```yml
name: precompile

on:
  push:
    tags:
      - 'v*'

jobs:
  linux:
    runs-on: ubuntu-latest
    env:
      MIX_ENV: "prod"
    steps:
      - uses: actions/checkout@v3
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "25.0.2"
          elixir-version: "1.13.4"
      - name: Install system dependecies
        run: |
          sudo apt-get update
          sudo apt-get install -y build-essential automake autoconf pkg-config bc m4 unzip zip \
            gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
            gcc-riscv64-linux-gnu g++-riscv64-linux-gnu
      - name: Mix Test
        run: |
          mix deps.get
          MIX_ENV=test mix test
      - name: Create precompiled library
        run: |
          export ELIXIR_MAKE_CACHE_DIR=$(pwd)/cache
          mkdir -p "${ELIXIR_MAKE_CACHE_DIR}"
          mix elixir_make.precompile
      - uses: softprops/action-gh-release@v1
        if: startsWith(github.ref, 'refs/tags/')
        with:
          files: |
            cache/*.tar.gz

  macos:
    runs-on: macos-11
    env:
      MIX_ENV: "prod"
    steps:
      - uses: actions/checkout@v3
      - name: Install erlang and elixir
        run: |
          brew install erlang elixir
          mix local.hex --force
          mix local.rebar --force
      - name: Mix Test
        run: |
          mix deps.get
          MIX_ENV=test mix test
      - name: Create precompiled library
        run: |
          export ELIXIR_MAKE_CACHE_DIR=$(pwd)/cache
          mkdir -p "${ELIXIR_MAKE_CACHE_DIR}"
          mix elixir_make.precompile
      - uses: softprops/action-gh-release@v1
        if: startsWith(github.ref, 'refs/tags/')
        with:
          files: |
            cache/*.tar.gz
```

### Generate checksum file
After CI has finished, you can fetch the precompiled binaries from GitHub.

```shell
$ MIX_ENV=prod mix elixir_make.fetch --all --ignore-unavailable
```

Meanwhile, a checksum file will be generated. In this example, the checksum file will be named as `checksum-cc_precompiler_example.exs` in current working directory.

This checksum file is extremely important in the scenario where you need to release a Hex package using precompiled NIFs. It's **MANDATORY** to include this file in your Hex package (by updating the `files` field in the `mix.exs`). Otherwise your package **won't work**.

```elixir
defp package do
  [
    files: [
      "lib",
      "checksum-*.exs",
      "mix.exs",
      # ...
    ],
    # ...
  ]
end
```

However, there is no need to track the checksum file in your version control system (git or other).

### (Optional) Test fetched artefacts can work locally
```shell
# delete previously built binaries so that
# elixir_make will try to restore the NIF library
# from the downloaded tarball file
$ rm -rf _build/prod/lib/cc_precompiler_example
# set to prod env and test everything
$ MIX_ENV=prod mix test
==> castore
Compiling 1 file (.ex)
Generated castore app
==> elixir_make
Compiling 5 files (.ex)
Generated elixir_make app
==> cc_precompiler
Compiling 1 file (.ex)
Generated cc_precompiler app

20:47:42.262 [debug] Restore NIF for current node from: /Users/cocoa/Library/Caches/cc_precompiler_example-nif-2.16-aarch64-apple-darwin-0.1.0.tar.gz
==> cc_precompiler_example
Compiling 1 file (.ex)
Generated cc_precompiler_example app
.

Finished in 0.01 seconds (0.00s async, 0.01s sync)
1 test, 0 failures

Randomized with seed 539590
```

## Recommended flow
To recap, the suggested flow is the following:

1. Choose an appropriate precompiler for your NIF library and set all necessary options in the `mix.exs`.
2. (Optional) Test if your NIF library compiles locally.

  ```shell
  mix compile
  mix test
  ```

3. (Optional) Test if your NIF library can precompile to all specified targets locally.
  ```shell
  MIX_ENV=prod mix elixir_make.precompile
  ```

4. Precompile your library on CI or locally.

  ```shell
  # locally
  MIX_ENV=prod mix elixir_make.precompile
  # CI
  # please see the docs above
  ```

5. Fetch precompiled binaries from GitHub.

  ```shell
  # only fetch artefact for current host
  MIX_ENV=prod mix elixir_make.fetch --only-local --print
  # fetch all
  MIX_ENV=prod mix elixir_make.fetch --all --print
  # to fetch all available artefacts at the moment
  MIX_ENV=prod mix elixir_make.fetch --all --print --ignore-unavailable
  ```

6. (Optional) Test if the downloaded artefacts works as expected.

  ```shell
  rm -rf _build/prod/lib/NIF_LIBRARY_NAME
  MIX_ENV=prod mix test
  ```

6. Update Hex package to include the checksum file.
7. Release the package to Hex.pm (make sure your release includes the correct files).


## Precompiler Module Developer

In this section, I'll walk you through creating a simple precompiler that utilises existing crosscompilers in the system.

### Create a new precompiler module

We start by creating a new elixir library, say `cc_precompiler`.

```shell
$ mix new cc_precompiler
* creating README.md
* creating .formatter.exs
* creating .gitignore
* creating mix.exs
* creating lib
* creating lib/cc_precompiler.ex
* creating test
* creating test/test_helper.exs
* creating test/cc_precompiler_test.exs

Your Mix project was created successfully.
You can use "mix" to compile it, test it, and more:

    cd cc_precompiler
    mix test

Run "mix help" for more commands.
```

Then in the `mix.exs` file, we add `:elixir_make` to `deps`.

```elixir
defp deps do
  [{:elixir_make, "~> 0.6", runtime: false}]
end
```

### Write the CC Precompiler

To create a precompiler module that is compatible with `elixir_make`, the module (`lib/cc_precompiler.ex`) need to implement a few callbacks defined in the `ElixirMake.Precompiler` beheviour.

The full project of `cc_precompiler` is available on [cocoa-xu/cc_precompiler](https://github.com/cocoa-xu/cc_precompiler).

```elixir
defmodule CCPrecompiler do
  @moduledoc """
  Precompile with existing crosscompiler in the system.
  """

  require Logger
  @behaviour ElixirMake.Precompiler

  # this is the default configuration for this demo precompiler module
  # for linux systems, it will detect for the following targets
  #   - aarch64-linux-gnu
  #   - riscv64-linux-gnu
  #   - arm-linux-gnueabihf
  # by trying to find the corresponding executable, i.e.,
  #   - aarch64-linux-gnu-gcc
  #   - riscv64-linux-gnu-gcc
  #   - gcc-arm-linux-gnueabihf
  # (this demo module will only try to find the CC executable, a step further
  # will be trying to compile a simple C/C++ program using them)
  @default_compilers %{
    {:unix, :linux} => %{
      "aarch64-linux-gnu" => {"aarch64-linux-gnu-gcc", "aarch64-linux-gnu-g++"},
      "riscv64-linux-gnu" => {"riscv64-linux-gnu-gcc", "riscv64-linux-gnu-g++"},
      "arm-linux-gnueabihf" => {"gcc-arm-linux-gnueabihf", "g++-arm-linux-gnueabihf"},
    },
    {:unix, :darwin} => %{
      "x86_64-apple-darwin" => {
        "gcc", "g++", "-arch x86_64", "-arch x86_64"
      },
      "aarch64-apple-darwin" => {
        "gcc", "g++", "-arch arm64", "-arch arm64"
      }
    }
  }
  @user_config Application.compile_env(Mix.Project.config[:app], :cc_precompile)
  @compilers Access.get(@user_config, :compilers, @default_compilers)
  @compilers_current_os Access.get(@compilers, :os.type(), %{})
  @impl ElixirMake.Precompiler
  def current_target do
    current_target_user_overwrite = Access.get(@user_config, :current_target)
    if current_target_user_overwrite do
      # overwrite current target triplet
      {:ok, current_target_user_overwrite}
    else
      # get current target triplet from `:erlang.system_info/1`
      system_architecture = to_string(:erlang.system_info(:system_architecture))
      current = String.split(system_architecture, "-", trim: true)
      case length(current) do
        4 ->
          {:ok, "#{Enum.at(current, 0)}-#{Enum.at(current, 2)}-#{Enum.at(current, 3)}"}
        3 ->
          case :os.type() do
            {:unix, :darwin} ->
              # could be something like aarch64-apple-darwin21.0.0
              # but we don't really need the last 21.0.0 part
              if String.match?(Enum.at(current, 2), ~r/^darwin.*/) do
                {:ok, "#{Enum.at(current, 0)}-#{Enum.at(current, 1)}-darwin"}
              else
                {:ok, system_architecture}
              end
            _ ->
              {:ok, system_architecture}
          end
        _ ->
          {:error, "cannot decide current target"}
      end
    end
  end

  @impl ElixirMake.Precompiler
  def all_supported_targets() do
    # this callback is expected to return a list of string for
    #   all supported targets by this precompiler. in this
    #   implementation, we will try to find a few crosscompilers
    #   available in the system.
    # Note that this implementation is mainly used for demostration
    #   purpose, therefore the hardcoded compiler names are used in
    #   DEBIAN/Ubuntu Linux (as I only installed these ones at the
    #   time of writting this example)
    with {:ok, current} <- current_target() do
      Enum.uniq([current] ++ find_all_available_targets())
    else
      _ ->
        []
    end
  end

  defp find_all_available_targets do
    @compilers_current_os
    |> Map.keys()
    |> Enum.map(&find_available_compilers(&1, Map.get(@compilers_current_os, &1)))
    |> Enum.reject(fn x -> x == nil end)
  end

  defp find_available_compilers(triplet, compilers) when is_tuple(compilers) do
    if System.find_executable(elem(compilers, 0)) do
      Logger.debug("Found compiler for #{triplet}")
      triplet
    else
      Logger.debug("Compiler not found for #{triplet}")
      nil
    end
  end

  defp find_available_compilers(triplet, invalid) do
    Mix.raise("Invalid configuration for #{triplet}, expecting a 2-tuple or 4-tuple, however, got #{inspect(invalid)}")
  end

  @impl ElixirMake.Precompiler
  def build_native(args) do
    # in this callback we just build the NIF library natively,
    #   and because this precompiler module is designed for NIF
    #   libraries that use C/C++ as the main language with Makefile,
    #   we can just call `ElixirMake.Compile.compile(args)`
    ElixirMake.Compile.compile(args)
  end

  @impl ElixirMake.Precompiler
  def precompile(args, targets) do
    # in this callback we compile the NIF library for each target given
    #   in the list `targets`
    # it's worth noting that the targets in the list could be a subset
    #   of all supported targets because it's possible that `elixir_make`
    #   would allow user to set a filter to keep targets they want in the
    #   future.
    saved_cwd = File.cwd!()
    cache_dir = ElixirMake.Artefact.cache_dir()

    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]
    nif_version = ElixirMake.Compile.current_nif_version()

    precompiled_artefacts =
      do_precompile(app, version, nif_version, args, targets, saved_cwd, cache_dir)

    with {:ok, target} <- current_target() do
      tar_filename = ElixirMake.Artefact.archive_filename(app, version, nif_version, target)
      cached_tar_gz = Path.join([cache_dir, tar_filename])
      ElixirMake.Artefact.restore_nif_file(cached_tar_gz, app)
    end

    Mix.Project.build_structure()
    {:ok, precompiled_artefacts}
  end

  defp get_cc_and_cxx(triplet, default \\ {"gcc", "g++"}) do
    case Access.get(@compilers_current_os, triplet, default) do
      {cc, cxx} ->
        {cc, cxx}
      {cc, cxx, cc_args, cxx_args} ->
        {"#{cc} #{cc_args}", "#{cxx} #{cxx_args}"}
    end
  end

  defp do_precompile(app, version, nif_version, args, targets, saved_cwd, cache_dir) do
    saved_cc = System.get_env("CC") || ""
    saved_cxx = System.get_env("CXX") || ""
    saved_cpp = System.get_env("CPP") || ""

    precompiled_artefacts =
      Enum.reduce(targets, [], fn target, checksums ->
        Logger.debug("Current compiling target: #{target}")
        ElixirMake.Artefact.make_priv_dir(app, :clean)

        {cc, cxx} = get_cc_and_cxx(target)
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
    ElixirMake.Artefact.write_checksum!(app, precompiled_artefacts)

    File.cd!(saved_cwd)
    System.put_env("CC", saved_cc)
    System.put_env("CXX", saved_cxx)
    System.put_env("CPP", saved_cpp)
    precompiled_artefacts
  end

  @impl ElixirMake.Precompiler
  def post_precompile() do
    write_metadata_to_file()
  end

  defp write_metadata_to_file() do
    app = Mix.Project.config()[:app]
    version = Mix.Project.config()[:version]
    nif_version = ElixirMake.Compile.current_nif_version()
    cache_dir = ElixirMake.Artefact.cache_dir()

    with {:ok, target} <- current_target() do
      archived_artefact_file =
        ElixirMake.Artefact.archive_filename(app, version, nif_version, target)

      metadata = %{
        app: app,
        cached_tar_gz: Path.join([cache_dir, archived_artefact_file]),
        target: target,
        targets: all_supported_targets(),
        version: version
      }

      ElixirMake.Artefact.write_metadata(app, metadata)
    end

    :ok
  end
end
```