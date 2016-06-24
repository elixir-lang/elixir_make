defmodule Mix.Tasks.Compile.ElixirMakeTest do
  use ExUnit.Case

  import Mix.Tasks.Compile.ElixirMake, only: [run: 1]
  import ExUnit.CaptureIO

  @fixture_project Path.expand("../../fixtures/my_app", __DIR__)

  defmodule Sample do
    def project do
      [app: :sample,
       version: "0.1.0"]
    end
  end

  setup do
    System.delete_env("MAKE")
    in_fixture(fn -> File.rm_rf!("Makefile") end)
    :ok
  end

  test "running with a specific executable" do
    in_fixture fn ->
      with_project_config [make_executable: "nonexistentmake"], fn ->
        assert_raise Mix.Error, ~r/not found in the path/, fn ->
          capture_io(fn -> run([]) end)
        end
      end
    end
  end

  test "running without a makefile" do
    msg = ~r/\ACould not compile with/

    in_fixture fn ->
      File.rm_rf!("Makefile")

      capture_io fn ->
        assert_raise Mix.Error, msg, fn -> run([]) end
      end
    end
  end

  test "running with a makefile" do
    in_fixture fn ->
      File.write! "Makefile", """
      target:
      \t@echo "hello"
      """

      assert capture_io(fn -> run([]) end) =~ "hello\n"
    end
  end

  test "specifying targets" do
    in_fixture fn ->
      File.write! "Makefile", """
      useless_target:
      \t@echo "nope"
      target:
      \t@echo "target"
      other_target:
      \t@echo "other target"
      """

      with_project_config [make_targets: ~w(target other_target)], fn ->
        output = capture_io(fn -> run([]) end)
        assert output =~ "target\n"
        assert output =~ "other target\n"
        refute output =~ "nope"
      end
    end
  end

  test "specifying a cwd" do
    in_fixture fn ->
      File.mkdir_p!("subdir")
      File.write! "subdir/Makefile", """
      all:
      \t@echo "subdir"
      """

      with_project_config [make_cwd: "subdir"], fn ->
        assert capture_io(fn -> run([]) end) =~ "subdir\n"
      end
    end
  end

 test "specifying env" do
    in_fixture fn ->
      File.write! "Makefile", """
      all:
      \t@echo $(HELLO)
      """

      with_project_config [make_env: %{"HELLO" => "WORLD"}], fn ->
        assert capture_io(fn -> run([]) end) =~ "WORLD\n"
      end
    end
  end

  test "specifying a makefile" do
    in_fixture fn ->
      File.write "MyMakefile", """
      all:
      \t@echo "my makefile"
      """

      with_project_config [make_makefile: "MyMakefile"], fn ->
        assert capture_io(fn -> run([]) end) =~ "my makefile\n"
      end
    end
  end

  test "specifying a custom error message" do
    in_fixture fn ->
      with_project_config [make_error_message: "try harder"], fn ->
        capture_io fn ->
          assert_raise Mix.Error, ~r/try harder/, fn -> run([]) end
        end
      end
    end
  end

  test "specifying targets to run when cleaning" do
    in_fixture fn ->
      File.write "Makefile", """
      all:
      \t@echo "all"
      clean:
      \t@echo "cleaning"
      """

      with_project_config [make_clean: ["clean"], compilers: [:elixir_make]], fn ->
        output = capture_io(fn -> Mix.Task.run("clean", []) end)
        refute output =~ "all\n"
        assert output =~ "cleaning\n"
      end
    end
  end

  test "user-defined executable through environment variable" do
    in_fixture fn ->
      System.put_env("MAKE", "nonexistentmake")
      with_project_config [], fn ->
        assert_raise Mix.Error, ~r/"nonexistentmake" not found in the path/, fn ->
          capture_io(fn -> run([]) end)
        end
      end
    end
  end

  test "user-defined executable with no arguments allowed" do
    in_fixture fn ->
      System.put_env("MAKE", "make -f makefile")
      with_project_config [], fn ->
        assert_raise Mix.Error, ~r/"make -f makefile" not found in the path/, fn ->
          capture_io(fn -> run([]) end)
        end
      end
    end
  end

  test "--verbose" do
    in_fixture fn ->
      File.write "MyMakefile", """
      foo:
      \t@echo foo
      bar\\ baz:
      \t@echo bar baz
      """

      with_project_config [make_makefile: "MyMakefile", make_targets: ["foo", "bar baz"]], fn ->
        output = capture_io(fn -> run(["--verbose"]) end)
        assert output =~ "Compiling with make:"
      end
    end
  end

  defp in_fixture(fun) do
    File.cd!(@fixture_project, fun)
  end

  defp with_project_config(config, fun) do
    Mix.Project.in_project(:my_app, @fixture_project, config, fn(_) -> fun.() end)
  end
end
