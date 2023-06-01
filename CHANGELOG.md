# Changelog

## v0.7.7 (2023-06-01)

  * Fix compiler in umbrella apps

## v0.7.6 (2023-03-17)

  * Do not display error message when a target is unavailable
  * Allow usage of castore 1.0

## v0.7.5 (2023-02-18)

  * Support precompiling for multiple NIF versions

## v0.7.4 (2023-02-17)

  * Preload Erlang/OTP applications for Elixir v1.15+

## v0.7.3 (2022-12-27)

  * Add `post_precompile_target` to `ElixirMake.Precompiler` behaviour

## v0.7.2 (2022-12-14)

  * Allow precompiler to configure behaviour for unavailable targets

## v0.7.1 (2022-12-07)

  * Use CACerts from Erlang/OTP 25 if available

## v0.7.0 (2022-12-02)

  * Support precompilation with custom precompilers
  * Don't pass default Erlang environment variables into make

## v0.6.3 (2021-10-19)

  * Fallback to `make` if `nmake` is not available on Windows.

## v0.6.2 (2020-12-03)

  * Fix permissions for some files in the repository.

## v0.6.1 (2020-09-07)

  * Warn on paths that contain spaces.
  * Use `gmake` on NetBSD.

## v0.6.0 (2019-06-10)

  * Start tracking CHANGELOG.
