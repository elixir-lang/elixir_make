# Precompilation guide
This guide has two sections, the first one is intended for precompiler module developers. It covers a minimal example of creating a precompiler module. The second section is intended for library developers who want their library to be able to use precompiled artefacts in a simple way.

- [Precompiler Module Developer](#precompiler-module-developer)
- [Library Developer](#library-developer)

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
To create a precompiler module that is compatible with `elixir_make`, the module (`lib/cc_precompiler.ex`) need to implement a few callbacks defined in the `Mix.Tasks.ElixirMake.Precompile` beheviour.

The full project of `cc_precompiler` is available on [cocoa-xu/cc_precompiler](https://github.com/cocoa-xu/cc_precompiler).

## Library Developer
The full demo project is available on [cocoa-xu/cc_precompiler_example](https://github.com/cocoa-xu/cc_precompiler_example).

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
    make_nif_filename: "nif",
    # cc_precompiler specific config
    cc_precompile_base_url: "https://github.com/USER/REPO/downloads/releases/v#{@version}",
    # ...
  ]
end
```

Note that there is an optional config key for elixir_make, `make_nif_filename`.

If the name (file extension does not count) of the shared library is different from your app's name, then `make_nif_filename` should be set. For example, if the app name is `"cc_precompiler_example"` while the name shared library is `"nif.so"` (or `"nif.dll"` on windows), then `make_nif_filename` should be set as `"nif"`.

The default value of `make_nif_filename` is `"#{Mix.Project.config()[:app]}"`, i.e., the app name.

### (Optional) Test the NIF code locally
To test the NIF code locally, you can either set `force_build` to `true` or append `"-dev"` to your NIF library's version string.

```elixir
@version "0.1.0"
def project do
  [
    # either append `"-dev"` to your NIF library's version string
    version: (if Mix.env() == :prod do @version else "#{@version}-dev" end),
    # or set force_build to true
    force_build: true,
    # ...
  ]
end
```

Doing so will let `elixir_make` to only compile for the current host instead of building for all available targets.

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

To precompile for all targets on a local machine, 

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
$ MIX_ENV=prod mix elixir_make.fetch --all --ignore-unavailable true
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

20:47:42.254 [debug] Download/Reuse, context: %{args: [], random_thing: 42}

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
    MIX_ENV=prod mix elixir_make.fetch --all --print --ignore-unavailable true
    ```

6. (Optional) Test if the downloaded artefacts works as expected.
    ```shell
    rm -rf _build/prod/lib/NIF_LIBRARY_NAME
    MIX_ENV=prod mix test
    ```

6. Update Hex package to include the checksum file.
7. Release the package to Hex.pm (make sure your release includes the correct files).
