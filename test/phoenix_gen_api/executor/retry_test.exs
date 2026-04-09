defmodule PhoenixGenApi.ExecutorRetryTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.Structs.{Request, FunConfig}
  alias PhoenixGenApi.ConfigDb

  # Helper module to track call counts for retry testing
  # Uses an Agent to coordinate state across multiple process calls
  setup do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {:ok, fail_counter} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(counter), do: Agent.stop(counter)
      if Process.alive?(fail_counter), do: Agent.stop(fail_counter)
    end)

    {:ok, counter: counter, fail_counter: fail_counter}
  end

  describe "retry with local execution" do
    test "no retry when retry is nil and execution fails", %{counter: counter} do
      config = %FunConfig{
        request_type: "test_no_retry",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :always_fail, [counter]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: nil
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_no_retry_req",
        request_type: "test_no_retry",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
      # Should have been called exactly once (no retry)
      assert Agent.get(counter, & &1) == 1
    end

    test "retries local execution on failure with number (equivalent to {:all_nodes, n})", %{
      counter: counter
    } do
      # Function fails first 2 times, succeeds on 3rd
      config = %FunConfig{
        request_type: "test_retry_number",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :fail_then_succeed, [counter, 2]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: 3
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_retry_number_req",
        request_type: "test_retry_number",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      # Called 3 times: initial + 2 retries
      assert Agent.get(counter, & &1) == 3
    end

    test "retries local execution with {:same_node, n}", %{counter: counter} do
      # Function fails first time, succeeds on 2nd
      config = %FunConfig{
        request_type: "test_retry_same_node",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :fail_then_succeed, [counter, 1]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:same_node, 2}
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_retry_same_node_req",
        request_type: "test_retry_same_node",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      # Called 2 times: initial + 1 retry
      assert Agent.get(counter, & &1) == 2
    end

    test "retries local execution with {:all_nodes, n}", %{counter: counter} do
      # Function fails first 2 times, succeeds on 3rd
      config = %FunConfig{
        request_type: "test_retry_all_nodes",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :fail_then_succeed, [counter, 2]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:all_nodes, 3}
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_retry_all_nodes_req",
        request_type: "test_retry_all_nodes",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      # Called 3 times: initial + 2 retries
      assert Agent.get(counter, & &1) == 3
    end

    test "returns error when all retries exhausted", %{counter: counter} do
      # Function always fails, retry 2 times
      config = %FunConfig{
        request_type: "test_retry_exhausted",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :always_fail, [counter]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: 2
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_retry_exhausted_req",
        request_type: "test_retry_exhausted",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
      # Called 3 times: initial + 2 retries
      assert Agent.get(counter, & &1) == 3
    end

    test "no retry when execution succeeds on first try", %{counter: counter} do
      config = %FunConfig{
        request_type: "test_no_retry_needed",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :always_succeed, [counter]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: 3
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_no_retry_needed_req",
        request_type: "test_no_retry_needed",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      # Should have been called exactly once (no retry needed)
      assert Agent.get(counter, & &1) == 1
    end

    test "retry with {:same_node, 1} retries exactly once", %{counter: counter} do
      # Function fails first time, succeeds on 2nd
      config = %FunConfig{
        request_type: "test_retry_once",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :fail_then_succeed, [counter, 1]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:same_node, 1}
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_retry_once_req",
        request_type: "test_retry_once",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      assert Agent.get(counter, & &1) == 2
    end

    test "retry with {:same_node, 0} is invalid config and function is unsupported" do
      config = %FunConfig{
        request_type: "test_retry_zero",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :always_succeed, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:same_node, 0}
      }

      # Config with retry: 0 is invalid, so ConfigDb won't add it
      ConfigDb.add(config)

      request = %Request{
        request_id: "test_retry_zero_req",
        request_type: "test_retry_zero",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      # Since config is invalid, function is not found
      assert result.success == false
      assert result.error =~ "unsupported function"
    end
  end

  describe "retry with remote execution" do
    test "no retry when retry is nil and remote execution fails" do
      # Use a non-existent node to simulate remote failure
      config = %FunConfig{
        request_type: "test_remote_no_retry",
        service: "test_service",
        nodes: [:nonexistent_node@localhost],
        choose_node_mode: :random,
        timeout: 1000,
        mfa: {Kernel, :apply, [__MODULE__, :remote_function, []]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: nil
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_remote_no_retry_req",
        request_type: "test_remote_no_retry",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
    end

    test "retries remote execution with {:same_node, n} on badrpc", %{fail_counter: fail_counter} do
      # Use a non-existent node - RPC will fail with badrpc
      config = %FunConfig{
        request_type: "test_remote_retry_same_node",
        service: "test_service",
        nodes: [:nonexistent_node@localhost],
        choose_node_mode: :random,
        timeout: 500,
        mfa: {__MODULE__, :track_remote_call, [fail_counter]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:same_node, 2}
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_remote_retry_same_node_req",
        request_type: "test_remote_retry_same_node",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
      # The RPC call itself won't execute on the remote node since it doesn't exist,
      # but the retry logic should attempt 1 + 2 = 3 times through execute_remote_with_fallback
    end

    test "retries remote execution with {:all_nodes, n} on badrpc" do
      # Use non-existent nodes - RPC will fail with badrpc
      config = %FunConfig{
        request_type: "test_remote_retry_all_nodes",
        service: "test_service",
        nodes: [:nonexistent_node1@localhost, :nonexistent_node2@localhost],
        choose_node_mode: :random,
        timeout: 500,
        mfa: {Kernel, :apply, [__MODULE__, :remote_function, []]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:all_nodes, 2}
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_remote_retry_all_nodes_req",
        request_type: "test_remote_retry_all_nodes",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
      # With {:all_nodes, 2}, it should retry 2 times across all available nodes
    end

    test "retries with number format (equivalent to {:all_nodes, n})" do
      config = %FunConfig{
        request_type: "test_remote_retry_number",
        service: "test_service",
        nodes: [:nonexistent_node@localhost],
        choose_node_mode: :random,
        timeout: 500,
        mfa: {Kernel, :apply, [__MODULE__, :remote_function, []]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: 2
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_remote_retry_number_req",
        request_type: "test_remote_retry_number",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
    end
  end

  describe "retry telemetry" do
    test "emits retry telemetry events", %{counter: counter} do
      # Attach a telemetry handler to capture retry events
      test_pid = self()

      :telemetry.attach(
        "test-retry-handler",
        [:phoenix_gen_api, :executor, :retry],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:retry_event, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-retry-handler")
      end)

      config = %FunConfig{
        request_type: "test_retry_telemetry",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :fail_then_succeed, [counter, 1]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:same_node, 2}
      }

      ConfigDb.add(config)

      request = %Request{
        request_id: "test_retry_telemetry_req",
        request_type: "test_retry_telemetry",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      Executor.execute!(request)

      # Should receive at least one retry event
      assert_received {:retry_event, %{attempt: _n}, %{mode: :same_node, type: :local}}
    after
      :telemetry.detach("test-retry-handler")
    end
  end

  # Test helper functions

  @doc """
  Always returns an error result. Increments the counter each call.
  """
  def always_fail(counter) do
    Agent.update(counter, &(&1 + 1))
    {:error, "always fails"}
  end

  @doc """
  Always returns a success result. Increments the counter each call.
  """
  def always_succeed(counter) do
    Agent.update(counter, &(&1 + 1))
    {:ok, "success"}
  end

  @doc """
  Fails for the first `fail_count` calls, then succeeds.
  Increments the counter each call.
  """
  def fail_then_succeed(counter, fail_count) do
    Agent.update(counter, &(&1 + 1))
    current = Agent.get(counter, & &1)

    if current <= fail_count do
      {:error, "fail on attempt #{current}"}
    else
      {:ok, "succeeded on attempt #{current}"}
    end
  end

  @doc """
  Tracks remote calls (used for remote retry testing).
  """
  def track_remote_call(counter) do
    Agent.update(counter, &(&1 + 1))
    {:ok, "remote call tracked"}
  end

  @doc """
  Simple remote function for testing.
  """
  def remote_function do
    {:ok, "remote result"}
  end
end
