defmodule PhoenixGenApiTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.Structs.{Request, FunConfig}

  describe "stop_stream/1" do
    test "stops stream with pid" do
      # Create a real stream call process
      request = %Request{
        request_id: "test_stream_req",
        request_type: "test_stream",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      config = %FunConfig{
        request_type: "test_stream",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :dummy_stream_function, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :stream,
        check_permission: false,
        request_info: false
      }

      args = %{
        request: request,
        fun_config: config,
        receiver: self()
      }

      {:ok, pid} = StreamCall.start_link(args)

      # Wait for initial message
      receive do
        {:stream_response, _} -> :ok
      after
        1000 -> :ok
      end

      # Stop the stream
      assert :ok = PhoenixGenApi.stop_stream(pid)

      # Should receive completion message
      receive do
        {:stream_response, response} ->
          assert response.has_more == false
      after
        1000 -> :ok
      end
    end
  end

  def dummy_stream_function do
    {:ok, :init}
  end
end
