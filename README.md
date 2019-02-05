# A Make compiler for Mix

[![Build Status](https://travis-ci.org/elixir-lang/elixir_make.svg?branch=master)](https://travis-ci.org/elixir-lang/elixir_make)

This project provides a Mix compiler that makes it straight-forward to use makefiles in your Mix projects.

## Usage

The package can be installed by adding `elixir_make` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:elixir_make, "~> 0.4", runtime: false}]
end
```

Still in your `mix.exs` file, you will need to add `:elixir_make` to your list of compilers in `project/0`:

```elixir
compilers: [:elixir_make] ++ Mix.compilers,
```

And that's it. The command above will invoke `make` for Unix, `nmake` for Windows and `gmake` for FreeBSD and OpenBSD. A "Makefile" file is expected at your project root for Unix systems and "Makefile.win" for Windows systems. Run `mix help compile.elixir_make` for more information and options.

## Environment variables
Environment variables can be passed in to `make` vie the `make_env` option.

```
make_env: %{"SOME_ENV_VAR" => "SOME ENV VAR"}
```

There are also several default environment variables set:

* `MIX_TARGET`
* `MIX_ENV`
* `MIX_BUILD_PATH` 
* `MIX_COMPILE_PATH` 
* `MIX_CONSOLIDATION_PATH` 
* `MIX_DEPS_PATH` 
* `MIX_MANIFEST_PATH` 
* `ERL_EI_LIBDIR`
* `ERL_EI_INCLUDE_DIR`
* `ERTS_INCLUDE_DIR`
* `ERL_INTERFACE_LIB_DIR`
* `ERL_INTERFACE_INCLUDE_DIR`

These may also be overwrote with the `make_env` option.

## Publishing a package to Hex.pm

When publishing a package to Hex.pm using `elixir_make` requires you to add
any file (such as the Makefile and any source files) to the `files` option.
See [the hex docs](https://hex.pm/docs/publish#adding-metadata-to-code-classinlinemixexscode)

```elixir
  defp package do
    [
      # ...
      files: [
        "lib", "LICENSE", "mix.exs", "README.md", # These are the default files
        "src/*.[ch]", "Makefile"], # You will need to add something like this.
      # ...
    ]
  end
```

## License

Same as Elixir.
