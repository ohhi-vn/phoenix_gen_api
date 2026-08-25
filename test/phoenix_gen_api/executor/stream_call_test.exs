defmodule PhoenixGenApi.StreamCallTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  # ConfigDb is already started by the application

  setup do
    unique = System.unique_integer([:positive])

    request = %Request{
      request_id: "stream_request_id_#{unique}",
      request_type: "test_stream_#{unique}",
      user_id: "user_123",
      device_id: "device_456",
      args: %{"query" => "test"}
    }

    config = %FunConfig{
      request_type: "test_stream_#{unique}",
      service: "test_service_#{unique}",
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

    {:ok, request: request, config: config, unique: unique}
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

    test "stops by request_id when the stream was started from the calling process",
         %{request: request, config: config} do
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

      assert :ok = StreamCall.stop(request.request_id)

      # Should receive completion message
      receive do
        {:stream_response, response} ->
          assert response.has_more == false
      after
        1000 -> flunk("Expected completion message")
      end

      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "returns {:error, :not_found} for an unknown request_id", %{request: request} do
      assert {:error, :not_found} = StreamCall.stop(request.request_id)
    end
  end

  describe "error paths" do
    test "sends an error response when the underlying call returns an error",
         %{request: request} do
      config = %FunConfig{
        request_type: request.request_type,
        service: "test_service_err",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_stream_error, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :stream,
        check_permission: false,
        request_info: true
      }

      {:ok, pid} =
        StreamCall.start_link(%{request: request, fun_config: config, receiver: self()})

      receive do
        {:stream_response, response} ->
          assert response.success == false
          assert response.error =~ "Internal Server Error"
      after
        1000 -> flunk("Expected error response")
      end

      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "includes the error details when detail_error is enabled", %{
      request: request,
      config: config
    } do
      Application.put_env(:phoenix_gen_api, :detail_error, true)

      on_exit(fn ->
        Application.delete_env(:phoenix_gen_api, :detail_error)
      end)

      {:ok, pid} =
        StreamCall.start_link(%{request: request, fun_config: config, receiver: self()})

      # Wait for init
      receive do
        {:stream_response, _} -> :ok
      after
        1000 -> :ok
      end

      send(pid, {:error, "specific failure detail"})

      receive do
        {:stream_response, response} ->
          assert response.success == false
          assert response.error =~ "specific failure detail"
      after
        1000 -> flunk("Expected detailed error message")
      end

      Process.sleep(100)
      refute Process.alive?(pid)
    end

    test "ignores unknown messages", %{request: request, config: config} do
      {:ok, pid} =
        StreamCall.start_link(%{request: request, fun_config: config, receiver: self()})

      # Wait for init
      receive do
        {:stream_response, _} -> :ok
      after
        1000 -> :ok
      end

      send(pid, :some_unknown_message)
      Process.sleep(50)
      assert Process.alive?(pid)

      StreamCall.stop(pid)
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

  def test_stream_error do
    {:error, "stream call failed"}
  end
end
