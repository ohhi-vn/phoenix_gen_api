defmodule PhoenixGenApi do
  @moduledoc """
  PhoenixGenApi is a framework for building distributed API systems with Phoenix.

  This library provides a comprehensive solution for handling API requests with support
  for multiple execution modes (sync, async, streaming), distributed node selection,
  permission checking, and automatic argument validation.

  ## Features

  - **Multiple Execution Modes**: Support for synchronous, asynchronous, streaming, and fire-and-forget requests
  - **Distributed Execution**: Execute functions on remote nodes with automatic node selection
  - **Node Selection Strategies**: Random, hash-based, round-robin, and custom selection strategies
  - **Automatic Argument Validation**: Type checking and conversion for request arguments
  - **Permission Control**: Built-in permission checking for requests
  - **Streaming Support**: Handle long-running operations with streaming responses
  - **Configuration Caching**: Efficient caching of function configurations with automatic updates

  ## Architecture

  The library consists of several key components:

  - `PhoenixGenApi.Executor` - Core execution engine for processing requests
  - `PhoenixGenApi.ConfigCache` - Caches function configurations for fast lookup
  - `PhoenixGenApi.ConfigPuller` - Pulls and updates configurations from remote services
  - `PhoenixGenApi.NodeSelector` - Selects target nodes based on configured strategies
  - `PhoenixGenApi.Permission` - Handles permission checking for requests
  - `PhoenixGenApi.ArgumentHandler` - Validates and converts request arguments
  - `PhoenixGenApi.StreamCall` - Manages streaming function calls

  ## Usage Example

  ### Basic Setup

  First, define your function configurations:

      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "get_user",
        service: "user_service",
        nodes: ["user@node1", "user@node2"],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {UserService, :get_user, []},
        arg_types: %{"user_id" => :string},
        arg_orders: ["user_id"],
        response_type: :sync,
        check_permission: {:arg, "user_id"},
        request_info: false
      }

      # Add configuration to cache
      PhoenixGenApi.ConfigCache.add(config)

  ### Execute Requests

      # Create a request
      request = %PhoenixGenApi.Structs.Request{
        request_id: "req_123",
        request_type: "get_user",
        user_id: "user_456",
        device_id: "device_789",
        args: %{"user_id" => "user_123"}
      }

      # Execute the request
      response = PhoenixGenApi.Executor.execute!(request)

  ### Streaming Requests

  For long-running operations, use streaming mode:

      stream_config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "process_data",
        service: "processing_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: :infinity,
        mfa: {DataProcessor, :process_large_dataset, []},
        arg_types: %{"dataset_id" => :string},
        arg_orders: ["dataset_id"],
        response_type: :stream,
        check_permission: false,
        request_info: true
      }

      # The streaming function should send results using StreamHelper:
      # StreamHelper.send_result(stream, chunk_data)
      # StreamHelper.send_last_result(stream, final_data)
      # Or: StreamHelper.send_complete(stream)

  ## Configuration

  Add to your `config.exs`:

      config :phoenix_gen_api, :gen_api,
        pull_timeout: 5_000,
        pull_interval: 30_000,
        detail_error: false,
        service_configs: [
          %{
            service: "user_service",
            nodes: ["user@node1", "user@node2"],
            module: "UserService",
            function: "get_config",
            args: []
          }
        ]

  ## Learn More

  For detailed information about specific components, see:

  - `PhoenixGenApi.Executor` - Request execution
  - `PhoenixGenApi.Structs.FunConfig` - Function configuration
  - `PhoenixGenApi.Structs.Request` - Request structure
  - `PhoenixGenApi.Structs.Response` - Response structure
  - `PhoenixGenApi.NodeSelector` - Node selection strategies
  """

  alias PhoenixGenApi.StreamCall

  @spec stop_stream(pid()) :: :ok
  @doc """
  Stops an active streaming call.

  This function gracefully terminates a streaming call process and sends a completion
  message to the receiver. The stream call process is identified by its PID.

  ## Parameters

    - `stream_pid` - The PID of the streaming call process to stop

  ## Returns

    - `:ok` - The stop signal was sent successfully

  ## Examples

      # Start a stream
      {:ok, stream_pid} = StreamCall.start_link(%{
        request: request,
        fun_config: config,
        receiver: self()
      })

      # Later, stop the stream
      PhoenixGenApi.stop_stream(stream_pid)

      # Receive the completion message
      receive do
        {:stream_response, response} ->
          assert response.has_more == false
      end

  ## Notes

  - The stream call will send a completion response to its receiver before terminating
  - This does not notify the data generator process; it only stops the stream relay
  - If you need to stop the data generation itself, handle that in your generator function
  """
  def stop_stream(request_id) do
    StreamCall.stop(request_id)
  end
end
