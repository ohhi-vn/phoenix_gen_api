defmodule PhoenixGenApi.ChannelHelpersTest.Handler do
  use PhoenixGenApi.ChannelHelpers, event: "custom_event"

  def push(socket, event, payload) do
    send(socket.ref, {:pushed, event, payload})
    socket
  end
end

defmodule PhoenixGenApi.ChannelHelpersTest.DefaultHandler do
  use PhoenixGenApi.ChannelHelpers

  def push(socket, event, payload) do
    send(socket.ref, {:pushed, event, payload})
    socket
  end
end

defmodule PhoenixGenApi.ChannelHelpersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias PhoenixGenApi.ChannelHelpersTest.{DefaultHandler, Handler}

  defp capture_debug(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp socket do
    %{ref: self()}
  end

  describe "handle_info/2" do
    test "pushes {:push, result} on the default event and returns the socket" do
      s = socket()
      assert {:noreply, ^s} = DefaultHandler.handle_info({:push, %{ok: true}}, s)
      assert_received {:pushed, "phoenix_gen_api", %{ok: true}}
    end

    test "pushes {:stream_response, result} on the default event" do
      s = socket()
      assert {:noreply, ^s} = DefaultHandler.handle_info({:stream_response, :chunk}, s)
      assert_received {:pushed, "phoenix_gen_api", :chunk}
    end

    test "pushes {:async_call, result} on the default event" do
      s = socket()
      assert {:noreply, ^s} = DefaultHandler.handle_info({:async_call, %{id: 1}}, s)
      assert_received {:pushed, "phoenix_gen_api", %{id: 1}}
    end

    test "pushes on the configured custom event name" do
      s = socket()
      assert {:noreply, ^s} = Handler.handle_info({:push, :data}, s)
      assert_received {:pushed, "custom_event", :data}
    end

    test "{:stream_started, request_id, pid} does not push and returns the socket" do
      s = socket()
      pid = self()
      assert {:noreply, ^s} = DefaultHandler.handle_info({:stream_started, "req_1", pid}, s)
      refute_received {:pushed, _, _}
    end

    test "logs a debug message when pushing a result" do
      s = socket()

      log =
        capture_debug(fn ->
          DefaultHandler.handle_info({:push, :x}, s)
        end)

      assert log =~ "[ChannelHelpers] push result: :x"
      assert log =~ "PhoenixGenApi.ChannelHelpersTest.DefaultHandler"
    end

    test "logs a debug message for stream responses" do
      s = socket()

      log =
        capture_debug(fn ->
          DefaultHandler.handle_info({:stream_response, :chunk}, s)
        end)

      assert log =~ "[ChannelHelpers] stream response: :chunk"
    end

    test "logs a debug message for async call results" do
      s = socket()

      log =
        capture_debug(fn ->
          DefaultHandler.handle_info({:async_call, :result}, s)
        end)

      assert log =~ "[ChannelHelpers] async call result: :result"
    end

    test "logs a debug message when a stream starts" do
      s = socket()

      log =
        capture_debug(fn ->
          DefaultHandler.handle_info({:stream_started, "req_1", self()}, s)
        end)

      assert log =~ "[ChannelHelpers] stream started: request_id=\"req_1\""
    end
  end
end