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

Then add `:elixir_make` to the `compilers` list, and set the type (`:nif` or `:port`) and `CCPrecompile` as the value for `:make_precompiler`.

```elixir
@version "0.1.0"
def project do
  [
    # ...
    compilers: [:elixir_make] ++ Mix.compilers(),
    # elixir_make specific config
    # required
    make_precompiler: {:nif, CCPrecompiler},
    make_precompiler_url: "https://github.com/cocoa-xu/cc_precompiler_example/releases/download/v#{@version}/@{artefact_filename}",

    # optional
    make_precompiler_filename: "nif",
    make_precompiler_priv_paths: ["nif.*"],
    make_precompiler_nif_versions: [
      versions: ["2.14", "2.15", "2.16"],
      availability: &target_available_for_nif_version?/2
    ]
    # ...
  ]
end
```

Another required field is `make_precompiler_url`. It is a URL template to the artefact file.

`@{artefact_filename}` in the URL template string will be replaced by corresponding artefact filenames when fetching them. For example, `cc_precompiler_example-nif-2.16-x86_64-linux-gnu-0.1.0.tar.gz`.

#### `make_precompiler_filename` (optional config key)

The first optional config key for elixir_make is `make_precompiler_filename`. If the name (file extension does not count) of the shared library is different from your app's name, then `make_precompiler_filename` should be set. For example, if the app name is `"cc_precompiler_example"` while the name shared library is `"nif.so"` (or `"nif.dll"` on windows), then `make_precompiler_filename` should be set as `"nif"`.

#### `make_precompiler_priv_paths` (optional config key)
The second optional config key is `make_precompiler_priv_paths`. For example, say the `priv` directory is organised as follows in Linux, macOS and Windows respectively,

```
# Linux
.
├── assets
│   ├── model.onnx
│   └── data.json
├── lib
│   ├── libpriv1.so
│   ├── libpriv2.so
│   └── libpriv3.so
└── nif.so

# macOS
.
├── assets
│   ├── model.onnx
│   └── data.json
├── lib
│   ├── libpriv1.dylib
│   ├── libpriv2.dylib
│   └── libpriv3.dylib
└── nif.so

# Windows
.
├── assets
│   ├── model.onnx
│   └── data.json
├── lib
│   ├── libpriv1.dll
│   ├── libpriv2.dll
│   └── libpriv3.dll
└── nif.dll
```

By default, everything in `priv` will be included in the precompiled tar file. However, files in `assets` can be very large or platform-independent, therefore, we would like to only include the `nif.so` (`nif.dll`) file and everything in the `lib` directory in the precompiled tar file to reduce the footprint. In this case, we can set `make_precompiler_priv_paths` to `["nif.so", "nif.dll", "lib"]`.

Of course, wildcards (`?`, `**`, `*`) are supported when specifiying files. For example, `["nif.*", "lib/*.so", "lib/*.dll", "lib/*.dylib"]` will include `nif.so` (Linux/macOS) or `nif.dll` (Windows), and `.so` or `.dll` files in the `lib` directory. 

Directory structures and symbolic links are preserved.

#### `make_precompiler_nif_versions` (optional config key)

The third optional config key is `make_precompiler_nif_versions`. The default value is 

```elixir
[versions: ["#{:erlang.system_info(:nif_version)}"]]
```

If you'd like to aim for an older NIF version, say `2.15` for Erlang/OTP 23 and 24, then you need to setup CI correspondingly and set the value of this key to `[versions: ["2.15", "2.16"]]`. This optional key will only be checked when downloading precompiled artefacts.

For some platforms maybe we only have precompiled artefacts after a certain NIF version, say for x86_64 Windows we have precompiled artefacts available when NIF version >= `2.16` while other platforms have precompiled artefacts available from NIF version >= `2.15`.

In such case we can inform `:elixir_make` that Windows targets don't have precompiled artefacts available except for NIF version `2.16` by passing a function to the `availability` sub-key.

```elixir
defp target_available_for_nif_version?(target, nif_version) do
  if String.contains?(target, "windows") do
    nif_version == "2.16"
  else
    true
  end
end
```

### (Optional) Customise Precompilation Targets

To override the default configuration, please set the `cc_precompile` key in `project`. For example,

```elixir

def project do
[ 
  # ...
  cc_precompile: [
    # optional config that provides a map of available compilers
    # on different systems
    compilers: %{
      # key (`:os.type()`)
      #   this allows us to provide different available targets 
      #   on different systems
      # value is a map that describes which compilers are available
      #
      # key == {:unix, :linux} => when compiling on Linux
      {:unix, :linux} => %{
        # key (target triplet) => `riscv64-linux-gnu`
        # value => `PREFIX`
        #   - for strings, the string will be used as the prefix of
        #         the C and C++ compiler respectively, i.e.,
        #         CC=`#{prefix}gcc`
        #         CXX=`#{prefix}g++`
        "riscv64-linux-gnu" => "riscv64-linux-gnu-",
        # key (target triplet) => `armv7l-linux-gnueabihf`
        # value => `{CC, CXX}`
        #   - for 2-tuples, the elements are the executable name of
        #         the C and C++ compiler respectively
        "armv7l-linux-gnueabihf" => {
          "arm-linux-gnueabihf-gcc",
          "arm-linux-gnueabihf-g++"
        },
        # key (target triplet) => `armv7l-linux-gnueabihf`
        # value => `{CC_EXECUTABLE, CXX_EXECUTABLE, CC_TEMPLATE, CXX_TEMPLATE}`
        #
        # - for 4-tuples, the first two elements are the same as in
        #       2-tuple, the third and fourth elements are the template
        #       string for CC and CPP/CXX. for example,
        #       
        #       the last entry below shows the example of using zig as the
        #       crosscompiler for `aarch64-linux-musl`, 
        #       the "CC" will be
        #           "zig cc -target aarch64-linux-musl", 
        #       and "CXX" and "CPP" will be
        #           "zig c++ -target aarch64-linux-musl"
        "aarch64-linux-musl" => {
          "zig", 
          "zig", 
          "<% cc %> cc -target aarch64-linux-musl", 
          "<% cxx %> c++ -target aarch64-linux-musl"
        }
      },
      # key == {:unix, :darwin} => when compiling on macOS
      {:unix, :darwin} => %{
        # key (target triplet) => `aarch64-apple-darwin`
        # value => `{CC, CXX}`
        "aarch64-apple-darwin" => {
          "gcc -arch arm64", "g++ -arch arm64"
        },
        # key (target triplet) => `aarch64-linux-musl`
        # value => `{CC_EXECUTABLE, CXX_EXECUTABLE, CC_TEMPLATE, CXX_TEMPLATE}`
        "aarch64-linux-musl" => {
          "zig",
          "zig",
          "<% cc %> cc -target aarch64-linux-musl",
          "<% cxx %> c++ -target aarch64-linux-musl"
        }
      }
    }
  ]
]
```

### (Optional) Test the NIF code locally

To test the NIF code locally, you can either set `force_build` to `true` or append `"-dev"` to your NIF library's version string.

```elixir
@version "0.1.0-dev"

def project do
  [
    # either append `"-dev"` to your NIF library's version string
    version: @version,
    # or set force_build to true
    make_force_build: true,
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
$ MIX_ENV=prod mix elixir_make.checksum --all --ignore-unavailable
```

Meanwhile, a checksum file will be generated. In this example, the checksum file will be named as `checksum-cc_precompiler_example.exs` in current working directory.

This checksum file is extremely important in the scenario where you need to release a Hex package using precompiled NIFs. It's **MANDATORY** to include this file in your Hex package (by updating the `files` field in the `mix.exs`). Otherwise your package **won't work**.

```elixir
defp package do
  [
    files: [
      "lib",
      "checksum.exs",
      "mix.exs",
      # ...
    ],
    # ...
  ]
end
```

However, there is no need to track the checksum file in your version control system (git or other), so consider adding it to your `.gitignore`.

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

### Recommended flow

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
  MIX_ENV=prod mix elixir_make.checksum --only-local --print
  # fetch all
  MIX_ENV=prod mix elixir_make.checksum --all --print
  # to fetch all available artefacts at the moment
  MIX_ENV=prod mix elixir_make.checksum --all --print --ignore-unavailable
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

  # This is the default configuration for this demo precompiler module
  # for linux systems, it will detect for the following targets
  #   - x86_64-linux-gnu
  #   - i686-linux-gnu
  #   - aarch64-linux-gnu
  #   - armv7l-linux-gnueabihf
  #   - riscv64-linux-gnu
  #   - powerpc64le-linux-gnu
  #   - s390x-linux-gnu
  # by trying to find the corresponding executable, i.e.,
  #   - x86_64-linux-gnu-gcc
  #   - i686-linux-gnu-gcc
  #   - aarch64-linux-gnu-gcc
  #   - arm-linux-gnueabihf-gcc
  #   - riscv64-linux-gnu-gcc
  #   - powerpc64le-linux-gnu-gcc
  #   - s390x-linux-gnu-gcc
  # (this module will only try to find the CC executable, a step further
  # will be trying to compile a simple C/C++ program using them)
  @default_compilers %{
    {:unix, :linux} => %{
      "x86_64-linux-gnu" => "x86_64-linux-gnu-",
      "i686-linux-gnu" => "i686-linux-gnu-",
      "aarch64-linux-gnu" => "aarch64-linux-gnu-",
      "armv7l-linux-gnueabihf" => "arm-linux-gnueabihf-",
      "riscv64-linux-gnu" => "riscv64-linux-gnu-",
      "powerpc64le-linux-gnu" => "powerpc64le-linux-gnu-",
      "s390x-linux-gnu" => "s390x-linux-gnu-"
    },
    {:unix, :darwin} => %{
      "x86_64-apple-darwin" => {
        "gcc",
        "g++",
        "<%= cc %> -arch x86_64",
        "<%= cxx %> -arch x86_64"
      },
      "aarch64-apple-darwin" => {
        "gcc",
        "g++",
        "<%= cc %> -arch arm64",
        "<%= cxx %> -arch arm64"
      }
    },
    {:win32, :nt} => %{
      "x86_64-windows-msvc" => {"cl", "cl"}
    }
  }

  defp default_compilers, do: @default_compilers
  defp user_config, do: Mix.Project.config()[:cc_precompile] || default_compilers()
  defp compilers, do: Access.get(user_config(), :compilers, default_compilers())
  defp compilers_current_os, do: Access.get(compilers(), :os.type(), %{})

  @impl ElixirMake.Precompiler
  def current_target do
    current_target_from_env = current_target_from_env()

    if current_target_from_env do
      # overwrite current target triplet
      {:ok, current_target_from_env}
    else
      current_target(:os.type())
    end
  end

  defp current_target_from_env do
    arch = System.get_env("TARGET_ARCH")
    os = System.get_env("TARGET_OS")
    abi = System.get_env("TARGET_ABI")

    if !Enum.all?([arch, os, abi], &Kernel.is_nil/1) do
      "#{arch}-#{os}-#{abi}"
    end
  end

  def current_target({:win32, _}) do
    processor_architecture =
      String.downcase(String.trim(System.get_env("PROCESSOR_ARCHITECTURE")))

    # https://docs.microsoft.com/en-gb/windows/win32/winprog64/wow64-implementation-details?redirectedfrom=MSDN
    partial_triplet =
      case processor_architecture do
        "amd64" ->
          "x86_64-windows-"

        "ia64" ->
          "ia64-windows-"

        "arm64" ->
          "aarch64-windows-"

        "x86" ->
          "x86-windows-"
      end

    {compiler, _} = :erlang.system_info(:c_compiler_used)

    case compiler do
      :msc ->
        {:ok, partial_triplet <> "msvc"}

      :gnuc ->
        {:ok, partial_triplet <> "gnu"}

      other ->
        {:ok, partial_triplet <> Atom.to_string(other)}
    end
  end

  def current_target({:unix, _}) do
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

  @impl ElixirMake.Precompiler
  def all_supported_targets(:compile) do
    # This callback is expected to return a list of string for
    # all supported targets by this precompiler. in this
    # implementation, we will try to find a few crosscompilers
    # available in the system.
    #
    # Note that this implementation is mainly used for demostration
    # purpose, therefore the hardcoded compiler names are used in
    # DEBIAN/Ubuntu Linux (as I only installed these ones at the
    # time of writting this example)
    with {:ok, current} <- current_target() do
      Enum.uniq([current] ++ find_all_available_targets())
    else
      _ ->
        []
    end
  end

  @impl ElixirMake.Precompiler
  def all_supported_targets(:fetch) do
    Enum.flat_map(compilers(), &Map.keys(elem(&1, 1)))
  end

  defp find_all_available_targets do
    Map.keys(compilers_current_os())
    |> Enum.map(&find_available_compilers(&1, Map.get(compilers_current_os(), &1)))
    |> Enum.reject(&is_nil/1)
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
    # In this callback we just build the NIF library natively,
    # and because this precompiler module is designed for NIF
    # libraries that use C/C++ as the main language with Makefile,
    # we can just call `ElixirMake.Precompiler.mix_compile(args)`
    #
    # It's also possible to forward this call to:
    #
    #     precompile(args, elem(current_target(), 1))
    #
    # This could be useful when the precompiler is using a universal
    # (cross-)compiler, say zig. in this way, the compiled binaries
    # (`mix compile`) will be consistent as the corrsponding precompiled
    # one (with `mix elixir_make.precompile`)
    #
    # However, if you'd prefer to having the same behaviour for `mix compile`
    # then the following line is okay
    ElixirMake.Precompiler.mix_compile(args)
  end

  @impl ElixirMake.Precompiler
  def precompile(args, target) do
    # Potentially clean the output directory to avoid conflicts
    File.rm!(Path.join(Mix.Project.app_path(), "priv"))

    saved_cc = System.get_env("CC") || ""
    saved_cxx = System.get_env("CXX") || ""
    saved_cpp = System.get_env("CPP") || ""

    Logger.debug("Current compiling target: #{target}")

    {cc, cxx} = get_cc_and_cxx(target)
    System.put_env("CC", cc)
    System.put_env("CXX", cxx)
    System.put_env("CPP", cxx)

    ElixirMake.Precompiler.mix_compile(args)

    System.put_env("CC", saved_cc)
    System.put_env("CXX", saved_cxx)
    System.put_env("CPP", saved_cpp)

    :ok
  end

  defp get_cc_and_cxx(triplet) do
    case Access.get(compilers_current_os(), triplet, nil) do
      nil ->
        cc = System.get_env("CC")
        cxx = System.get_env("CXX")
        cpp = System.get_env("CPP")

        case {cc, cxx, cpp} do
          {nil, _, _} ->
            {"gcc", "g++"}

          {_, nil, nil} ->
            {"gcc", "g++"}

          {_, _, nil} ->
            {cc, cxx}

          {_, nil, _} ->
            {cc, cpp}

          {_, _, _} ->
            {cc, cxx}
        end

      {cc, cxx} ->
        {cc, cxx}

      prefix when is_binary(prefix) ->
        {"#{prefix}gcc", "#{prefix}g++"}

      {cc, cxx, cc_args, cxx_args} ->
        {"#{cc} #{cc_args}", "#{cxx} #{cxx_args}"}
    end
  end

  @impl ElixirMake.Precompiler
  def post_precompile_target(target) do
    # It's possible to do some cleanup work
    # in this optionall callback
    # it will be called when `target` is properly archived
    # so you may safely delete all target-specific files,
    # like call `make clean`
    Logger.debug("Post target archive")
  end

  @impl ElixirMake.Precompiler
  def post_precompile() do
    # It's possible to do some post precompilation work
    # in this optionall callback
    # after all precompile targets are compiled.
    Logger.debug("Post precompile")
  end
end
```
