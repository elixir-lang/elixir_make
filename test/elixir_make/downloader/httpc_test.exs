defmodule ElixirMake.Downloader.HttpcTest do
  use ExUnit.Case, async: true

  alias ElixirMake.Downloader.Httpc

  setup_all do
    if function_exported?(Mix, :ensure_application!, 1) do
      Mix.ensure_application!(:inets)
      Mix.ensure_application!(:ssl)
      Mix.ensure_application!(:crypto)
    end

    :ok
  end

  test "downloads a response whose headers exceed httpc's default limit" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    # GitHub's release-download redirects send about 11 KB of headers.
    padding = String.duplicate("a", 12_288)

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, _request} = :gen_tcp.recv(socket, 0)

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nx-padding: #{padding}\r\ncontent-length: 3\r\nconnection: close\r\n\r\nnif"
        )

      :gen_tcp.close(socket)
    end)

    assert Httpc.download("http://127.0.0.1:#{port}/nif.tar.gz") == {:ok, "nif"}
  end
end
