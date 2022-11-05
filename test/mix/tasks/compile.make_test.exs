defmodule Mix.Tasks.Compile.ElixirMakeTest do
  use ExUnit.Case

  import Mix.Tasks.Compile.ElixirMake, only: [run: 1]
  import ExUnit.CaptureIO

  @fixture_project Path.expand("../../fixtures/my_app", __DIR__)

  defmodule Sample do
    def project do
      [app: :sample, version: "0.1.0"]
    end
  end

  setup do
    System.delete_env("MAKE")
    System.delete_env("ERL_EI_LIBDIR")
    System.delete_env("ERL_EI_INCLUDE_DIR")
    System.delete_env("ERTS_INCLUDE_DIR")
    System.delete_env("ERL_INTERFACE_LIB_DIR")
    System.delete_env("ERL_INTERFACE_INCLUDE_DIR")

    in_fixture(fn ->
      File.rm_rf!("Makefile")
      File.rm_rf!("_build")
      File.rm_rf!("priv")
    end)

    :ok
  end

  test "running with a specific executable" do
    in_fixture(fn ->
      with_project_config([make_executable: "nonexistentmake"], fn ->
        assert_raise Mix.Error, ~r/not found in the path/, fn ->
          capture_io(fn -> run([]) end)
        end
      end)
    end)
  end

  test "running without a makefile" do
    msg = ~r/\ACould not compile with/

    in_fixture(fn ->
      File.rm_rf!("Makefile")

      capture_io(fn ->
        assert_raise Mix.Error, msg, fn -> run([]) end
      end)
    end)
  end

  test "running with a makefile" do
    in_fixture(fn ->
      File.write!("Makefile", """
      target:
      \t@echo "hello"
      """)

      assert capture_io(fn -> run([]) end) =~ "hello\n"
    end)
  end

  test "specifying targets" do
    in_fixture(fn ->
      File.write!("Makefile", """
      useless_target:
      \t@echo "nope"
      target:
      \t@echo "target"
      other_target:
      \t@echo "other target"
      """)

      with_project_config([make_targets: ~w(target other_target)], fn ->
        output = capture_io(fn -> run([]) end)
        assert output =~ "target\n"
        assert output =~ "other target\n"
        refute output =~ "nope"
      end)
    end)
  end

  test "specifying a cwd" do
    in_fixture(fn ->
      File.mkdir_p!("subdir")

      File.write!("subdir/Makefile", """
      all:
      \t@echo "subdir"
      """)

      with_project_config([make_cwd: "subdir"], fn ->
        assert capture_io(fn -> run([]) end) =~ "subdir\n"
      end)
    end)
  end

  test "warns if the cwd contains a space" do
    in_fixture(fn ->
      File.mkdir_p!("subdir with spaces")

      File.write!("subdir with spaces/Makefile", """
      all:
      \t@echo "subdir_with_spaces"
      """)

      capture_io(:stdio, fn ->
        with_project_config([make_cwd: "subdir with spaces"], fn ->
          assert capture_io(:stderr, fn -> run([]) end) =~
                   "the absolute path to the makefile for this project contains spaces."
        end)
      end)
    end)
  end

  test "specifying env" do
    in_fixture(fn ->
      File.write!("Makefile", """
      all:
      \t@echo $(HELLO)
      """)

      with_project_config([make_env: %{"HELLO" => "WORLD"}], fn ->
        assert capture_io(fn -> run([]) end) =~ "WORLD\n"
      end)
    end)
  end

  test "default env" do
    in_fixture(fn ->
      File.write!("Makefile", """
      all:
      \t@echo $(MIX_TARGET)
      \t@echo $(MIX_ENV)
      \t@echo $(MIX_BUILD_PATH)
      \t@echo $(MIX_COMPILE_PATH)
      \t@echo $(MIX_DEPS_PATH)
      """)

      with_project_config([], fn ->
        assert capture_io(fn -> run([]) end) =~ """
               my_app
               host
               test
               #{@fixture_project}/_build/test
               #{@fixture_project}/_build/test/lib/my_app/ebin
               #{@fixture_project}/deps
               """
      end)
    end)
  end

  test "erts env vars don't clobber existing vars" do
    in_fixture(fn ->
      fake_dir = "/tmp/erts/"
      System.put_env("ERL_EI_LIBDIR", fake_dir)
      System.put_env("ERL_EI_INCLUDE_DIR", fake_dir)
      System.put_env("ERTS_INCLUDE_DIR", fake_dir)
      System.put_env("ERL_INTERFACE_LIB_DIR", fake_dir)
      System.put_env("ERL_INTERFACE_INCLUDE_DIR", fake_dir)

      File.write!("Makefile", """
      all:
      \t@echo $(ERL_EI_LIBDIR)
      \t@echo $(ERL_EI_INCLUDE_DIR)
      \t@echo $(ERTS_INCLUDE_DIR)
      \t@echo $(ERL_INTERFACE_LIB_DIR)
      \t@echo $(ERL_INTERFACE_INCLUDE_DIR)
      """)

      with_project_config([], fn ->
        assert capture_io(fn -> run([]) end) =~ """
               #{fake_dir}
               #{fake_dir}
               #{fake_dir}
               #{fake_dir}
               #{fake_dir}
               """
      end)
    end)
  end

  test "overwrite default env" do
    in_fixture(fn ->
      File.write!("Makefile", """
      all:
      \t@echo $(MIX_ENV)
      """)

      with_project_config([make_env: %{"MIX_ENV" => "SUPER_CUSTOM"}], fn ->
        assert capture_io(fn -> run([]) end) =~ "SUPER_CUSTOM\n"
      end)
    end)
  end

  test "specifying a makefile" do
    in_fixture(fn ->
      File.write("MyMakefile", """
      all:
      \t@echo "my makefile"
      """)

      with_project_config([make_makefile: "MyMakefile"], fn ->
        assert capture_io(fn -> run([]) end) =~ "my makefile\n"
      end)
    end)
  end

  test "specifying a custom error message" do
    in_fixture(fn ->
      with_project_config([make_error_message: "try harder"], fn ->
        capture_io(fn ->
          assert_raise Mix.Error, ~r/try harder/, fn -> run([]) end
        end)
      end)
    end)
  end

  test "specifying targets to run when cleaning" do
    in_fixture(fn ->
      File.write("Makefile", """
      all:
      \t@echo "all"
      clean:
      \t@echo "cleaning"
      """)

      with_project_config([make_clean: ["clean"], compilers: [:elixir_make]], fn ->
        output = capture_io(fn -> Mix.Task.run("clean", []) end)
        refute output =~ "all\n"
        assert output =~ "cleaning\n"
      end)
    end)
  end

  test "user-defined executable through environment variable" do
    in_fixture(fn ->
      System.put_env("MAKE", "nonexistentmake")

      with_project_config([], fn ->
        assert_raise Mix.Error, ~r/"nonexistentmake" not found in the path/, fn ->
          capture_io(fn -> run([]) end)
        end
      end)
    end)
  end

  test "user-defined executable with no arguments allowed" do
    in_fixture(fn ->
      System.put_env("MAKE", "make -f makefile")

      with_project_config([], fn ->
        assert_raise Mix.Error, ~r/"make -f makefile" not found in the path/, fn ->
          capture_io(fn -> run([]) end)
        end
      end)
    end)
  end

  test "--verbose" do
    in_fixture(fn ->
      File.write("MyMakefile", """
      foo:
      \t@echo foo
      bar\\ baz:
      \t@echo bar baz
      """)

      with_project_config([make_makefile: "MyMakefile", make_targets: ["foo", "bar baz"]], fn ->
        output = capture_io(fn -> run(["--verbose"]) end)
        assert output =~ "Compiling with make:"
      end)
    end)
  end

  test "additional args to make" do
    in_fixture(fn ->
      File.write("Makefile", """
      all:
      \t@echo "all"
      """)

      with_project_config([make_args: ["--print-directory"]], fn ->
        output = capture_io(fn -> run([]) end)
        assert output =~ "make: Entering directory"
      end)
    end)
  end

  test "build_embedded doesn't clobber build artifacts" do
    in_fixture(fn ->
      build_file_path = "./_build/test/lib/my_app/priv/build_file"

      File.mkdir!("priv")

      File.write!("Makefile", """
      all:
      \ttouch #{build_file_path}
      """)

      with_project_config([build_embedded: true], fn ->
        refute File.exists?(build_file_path)

        capture_io(fn ->
          Mix.Tasks.Compile.run([])
        end)

        assert File.exists?(build_file_path)
      end)
    end)
  end

  test "precompiler should only include specified files" do
    in_fixture(fn ->
      include_this = "include_this"
      build_file = "build_file"

      precompile_config = [
        make_precompiler: MyApp.Precompiler,
        make_precompiler_priv_paths: [include_this, build_file],
        make_force_build: true
      ]

      cache_dir = "./cache"
      File.mkdir_p!(cache_dir)
      System.put_env("ELIXIR_MAKE_CACHE_DIR", cache_dir)

      File.mkdir!("priv")
      priv_dir = "./_build/test/lib/my_app/priv"
      build_file_path = Path.join([priv_dir, build_file])
      include_this_path = Path.join([priv_dir, include_this])
      exclude_this_path = Path.join([priv_dir, "exclude_this"])

      File.write!("Makefile", """
      all:
      \ttouch #{build_file_path}
      \ttouch #{include_this_path}
      \ttouch #{exclude_this_path}
      """)

      with_project_config(precompile_config, fn ->
        refute File.exists?(build_file_path)
        refute File.exists?(include_this_path)
        refute File.exists?(exclude_this_path)

        capture_io(fn ->
          Mix.Tasks.ElixirMake.Precompile.run([])
        end)

        assert File.exists?(build_file_path)
        assert File.exists?(include_this_path)
        assert File.exists?(exclude_this_path)

        precompiled_tar_file =
          "./cache/my_app-nif-#{ElixirMake.Precompiler.current_nif_version()}-target-1.0.0.tar.gz"

        extract_to = "./cache/priv"
        :erl_tar.extract(precompiled_tar_file, [:compressed, {:cwd, extract_to}])

        build_file_path = Path.join([extract_to, build_file])
        include_this_path = Path.join([extract_to, include_this])
        exclude_this_path = Path.join([extract_to, "exclude_this"])

        assert File.exists?(build_file_path)
        assert File.exists?(include_this_path)
        assert !File.exists?(exclude_this_path)
      end)
    end)
  end

  defp in_fixture(fun) do
    File.cd!(@fixture_project, fun)
  end

  defp with_project_config(config, fun) do
    Mix.Project.in_project(:my_app, @fixture_project, config, fn _ -> fun.() end)
  end
end
