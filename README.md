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

## License

Same as Elixir.
