defmodule ElixirMake.Precompiler do
  @moduledoc """
  The behaviour for precompiler modules.
  """

  @typedoc """
  Target triplet.
  """
  @type target :: String.t()

  @doc """
  This callback should return a list of triplets ("arch-os-abi") for all supported targets
  of the given operation.

  For the `:compile` operation, `all_supported_targets` should return a list of targets that
  the current host is capable of (cross-)compiling to.

  For the `:fetch` operation, `all_supported_targets` should return the full list of targets.

  For example, GitHub Actions provides Linux, macOS and Windows CI hosts, when `operation` is
  `:compile`, the precompiler might return `["x86_64-linux-gnu"]` if it is running in the Linux
  CI environment, while returning `["x86_64-apple-darwin", "aarch64-apple-darwin"]` on macOS,
  or `["amd64-windows", "x86-windows"]` on Windows platform.

  When `operation` is `:fetch`, the precompiler should return the full list. The full list for
  the above example should be:

    [
      "x86_64-linux-gnu",
      "x86_64-apple-darwin",
      "aarch64-apple-darwin",
      "amd64-windows",
      "x86-windows"
    ]

  This allows the precompiler to do the compilation work in multilple hosts and gather all the
  artefacts later with `mix elixir_make.fetch --all`.
  """
  @callback all_supported_targets(operation :: :compile | :fetch) :: [target]

  @doc """
  This callback should return the target triplet for current node.
  """
  @callback current_target() :: {:ok, target} | {:error, String.t()}

  @doc """
  This callback will be invoked when the user executes the `mix compile`
  (or `mix compile.elixir_make`) command.

  The precompiler should then compile the NIF library "natively". Note that
  it is possible for the precompiler module to pick up other environment variables
  like `TARGET_ARCH=aarch64` and adjust compile arguments correspondingly.
  """
  @callback build_native(OptionParser.argv()) :: :ok | {:ok, []} | no_return

  @doc """
  This optional callback should return the precompiler's specific cache directory.

  If not implemented, `ElixirMake.Artefact.cache_dir()` will be used as the default value.

  """
  @callback cache_dir() :: String.t()

  @doc """
  This callback should precompile the library to the given target(s).

  Returns `:ok` if the requested target has successfully compiled.
  """
  @callback precompile(OptionParser.argv(), target) :: :ok | {:error, String.t()} | no_return

  @doc """
  Optional post actions to run after all precompilation tasks are done.

  It will only be called at the end of the `mix elixir_make.precompile` command.
  For example, actions can be archiving all precompiled artefacts and uploading
  the archive file to an object storage server.
  """
  @callback post_precompile() :: :ok

  @optional_callbacks post_precompile: 0, cache_dir: 0
end
