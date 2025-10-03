defmodule PhoenixGenApi.StreamCallTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.Structs.{Request, FunConfig}

  # ConfigCache is already started by the application

  setup do
    request = %Request{
      request_id: "stream_request_id",
      request_type: "test_stream",
      user_id: "user_123",
      device_id: "device_456",
      args: %{"query" => "test"}
    }

    config = %FunConfig{
      request_type: "test_stream",
      service: "test_service",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :test_stream_function, []},
      arg_types: %{"query" => :string},
      arg_orders: ["query"],
      response_type: :stream,
      check_permission: false,
      request_info: true
    }

    {:ok, request: request, config: config}
  end

  describe "start_link/1" do
    test "starts stream call process", %{request: request, config: config} do
      args = %{
        request: request,
        fun_config: config,
        receiver: self()
      }

      {:ok, pid} = StreamCall.start_link(args)
      assert Process.alive?(pid)

      # Wait for stream to complete
      receive do
        {:stream_response, _response} ->
          StreamCall.stop(pid)
          :ok
      after
        1000 -> flunk("Expected stream response")
      end
    end

    test "uses self() as receiver when nil", %{request: request, config: config} do
      args = %{
        request: request,
        fun_config: config,
        receiver: nil
      }

      {:ok, pid} = StreamCall.start_link(args)
      assert Process.alive?(pid)

      # Receive initial response
      receive do
        {:stream_response, _response} ->
          StreamCall.stop(pid)
          :ok
      after
        1000 -> flunk("Expected stream response")
      end
    end
  end

  describe "stop/1" do
    test "stops the stream call process", %{request: request, config: config} do
      args = %{
        request: request,
        fun_config: config,
        receiver: self()
      }

      {:ok, pid} = StreamCall.start_link(args)

      # Wait for initial message
      receive do
        {:stream_response, _} ->
          :ok
      after
        1000 -> :ok
      end

      StreamCall.stop(pid)

      # Should receive completion message
      receive do
        {:stream_response, response} ->
          assert response.has_more == false
      after
        1000 -> flunk("Expected completion message")
      end

      # Process should eventually stop
      Process.sleep(100)
      refute Process.alive?(pid)
    end
  end

  describe "handle_info/2 messages" do
    test "handles :result message", %{request: request, config: config} do
      args = %{
        request: request,
        fun_config: config,
        receiver: self()
      }

      {:ok, pid} = StreamCall.start_link(args)

      # Wait for init
      receive do
        {:stream_response, _} -> :ok
      after
        1000 -> :ok
      end

      send(pid, {:result, "data chunk 1"})

      receive do
        {:stream_response, response} ->
          assert response.result == "data chunk 1"
          assert response.has_more == true
          StreamCall.stop(pid)
      after
        1000 -> flunk("Expected result message")
      end
    end

    test "handles :last_result message", %{request: request, config: config} do
      args = %{
        request: request,
        fun_config: config,
        receiver: self()
      }

      {:ok, pid} = StreamCall.start_link(args)

      # Wait for init
      receive do
        {:stream_response, _} -> :ok
      after
        1000 -> :ok
      end

      send(pid, {:last_result, "final data"})

      receive do
        {:stream_response, response} ->
          assert response.result == "final data"
          assert response.has_more == false
      after
        1000 -> flunk("Expected last result message")
      end

      # Process should stop
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "handles :error message", %{request: request, config: config} do
      args = %{
        request: request,
        fun_config: config,
        receiver: self()
      }

      {:ok, pid} = StreamCall.start_link(args)

      # Wait for init
      receive do
        {:stream_response, _} -> :ok
      after
        1000 -> :ok
      end

      send(pid, {:error, "stream error"})

      receive do
        {:stream_response, response} ->
          assert response.success == false
          assert response.error =~ "Internal Server Error"
      after
        1000 -> flunk("Expected error message")
      end

      # Process should stop
      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "handles :complete message", %{request: request, config: config} do
      args = %{
        request: request,
        fun_config: config,
        receiver: self()
      }

      {:ok, pid} = StreamCall.start_link(args)

      # Wait for init
      receive do
        {:stream_response, _} -> :ok
      after
        1000 -> :ok
      end

      send(pid, :complete)

      receive do
        {:stream_response, response} ->
          assert response.has_more == false
          assert response.success == true
      after
        1000 -> flunk("Expected complete message")
      end

      # Process should stop
      Process.sleep(100)
      refute Process.alive?(pid)
    end
  end

  # Helper test function
  def test_stream_function(_query, _request_info) do
    {:ok, :init}
  end
end
