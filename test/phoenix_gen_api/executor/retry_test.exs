defmodule PhoenixGenApi.ExecutorRetryTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  # Helper module to track call counts for retry testing
  # Uses an Agent to coordinate state across multiple process calls
  setup do
    unique = System.unique_integer([:positive])
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {:ok, fail_counter} = Agent.start_link(fn -> 0 end)
    {:ok, config_tracker} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      # Clean up any configs added during the test
      # Read the list BEFORE stopping the agent
      configs_to_clean =
        if Process.alive?(config_tracker) do
          Agent.get(config_tracker, & &1)
        else
          []
        end

      Enum.each(configs_to_clean, fn {service, request_type} ->
        ConfigDb.delete(service, request_type)
      end)

      # Clean up agents
      if Process.alive?(counter), do: Agent.stop(counter)
      if Process.alive?(fail_counter), do: Agent.stop(fail_counter)
      if Process.alive?(config_tracker), do: Agent.stop(config_tracker)
    end)

    {:ok,
     counter: counter, fail_counter: fail_counter, config_tracker: config_tracker, unique: unique}
  end

  describe "retry with local execution" do
    test "no retry when retry is nil and execution fails", %{
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      config = %FunConfig{
        request_type: "test_no_retry_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_no_retry_req_#{unique}",
        request_type: "test_no_retry_#{unique}",
        service: "test_service_#{unique}",
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
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      # Function fails first 2 times, succeeds on 3rd
      config = %FunConfig{
        request_type: "test_retry_number_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_retry_number_req_#{unique}",
        request_type: "test_retry_number_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      # Called 3 times: initial + 2 retries
      assert Agent.get(counter, & &1) == 3
    end

    test "retries local execution with {:same_node, n}", %{
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      # Function fails first time, succeeds on 2nd
      config = %FunConfig{
        request_type: "test_retry_same_node_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_retry_same_node_req_#{unique}",
        request_type: "test_retry_same_node_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      # Called 2 times: initial + 1 retry
      assert Agent.get(counter, & &1) == 2
    end

    test "retries local execution with {:all_nodes, n}", %{
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      # Function fails first 2 times, succeeds on 3rd
      config = %FunConfig{
        request_type: "test_retry_all_nodes_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_retry_all_nodes_req_#{unique}",
        request_type: "test_retry_all_nodes_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      # Called 3 times: initial + 2 retries
      assert Agent.get(counter, & &1) == 3
    end

    test "returns error when all retries exhausted", %{
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      # Function always fails, retry 2 times
      config = %FunConfig{
        request_type: "test_retry_exhausted_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_retry_exhausted_req_#{unique}",
        request_type: "test_retry_exhausted_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
      # Called 3 times: initial + 2 retries
      assert Agent.get(counter, & &1) == 3
    end

    test "no retry when execution succeeds on first try", %{
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      config = %FunConfig{
        request_type: "test_no_retry_needed_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_no_retry_needed_req_#{unique}",
        request_type: "test_no_retry_needed_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      # Should have been called exactly once (no retry needed)
      assert Agent.get(counter, & &1) == 1
    end

    test "retry with {:same_node, 1} retries exactly once", %{
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      # Function fails first time, succeeds on 2nd
      config = %FunConfig{
        request_type: "test_retry_once_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_retry_once_req_#{unique}",
        request_type: "test_retry_once_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true
      assert Agent.get(counter, & &1) == 2
    end

    test "retry with {:same_node, 0} is invalid config and function is unsupported", %{
      config_tracker: config_tracker,
      unique: unique
    } do
      config = %FunConfig{
        request_type: "test_retry_zero_#{unique}",
        service: "test_service_#{unique}",
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
      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_retry_zero_req_#{unique}",
        request_type: "test_retry_zero_#{unique}",
        service: "test_service_#{unique}",
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
    test "no retry when retry is nil and remote execution fails", %{
      config_tracker: config_tracker,
      unique: unique
    } do
      # Use a non-existent node to simulate remote failure
      config = %FunConfig{
        request_type: "test_remote_no_retry_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_remote_no_retry_req_#{unique}",
        request_type: "test_remote_no_retry_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
    end

    test "retries remote execution with {:same_node, n} on badrpc", %{
      fail_counter: fail_counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      # Use a non-existent node - RPC will fail with badrpc
      config = %FunConfig{
        request_type: "test_remote_retry_same_node_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_remote_retry_same_node_req_#{unique}",
        request_type: "test_remote_retry_same_node_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
      # The RPC call itself won't execute on the remote node since it doesn't exist,
      # but the retry logic should attempt 1 + 2 = 3 times through execute_remote_with_fallback
    end

    test "retries remote execution with {:all_nodes, n} on badrpc", %{
      config_tracker: config_tracker,
      unique: unique
    } do
      # Use non-existent nodes - RPC will fail with badrpc
      config = %FunConfig{
        request_type: "test_remote_retry_all_nodes_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_remote_retry_all_nodes_req_#{unique}",
        request_type: "test_remote_retry_all_nodes_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
      # With {:all_nodes, 2}, it should retry 2 times across all available nodes
    end

    test "retries with number format (equivalent to {:all_nodes, n})", %{
      config_tracker: config_tracker,
      unique: unique
    } do
      config = %FunConfig{
        request_type: "test_remote_retry_number_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_remote_retry_number_req_#{unique}",
        request_type: "test_remote_retry_number_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
    end
  end

  describe "retry telemetry" do
    test "emits retry telemetry events", %{
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      test_pid = self()
      handler_id = "test-retry-handler-#{unique}"

      :telemetry.attach(
        handler_id,
        [:phoenix_gen_api, :executor, :retry],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:retry_event, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      config = %FunConfig{
        request_type: "test_retry_telemetry_#{unique}",
        service: "test_service_#{unique}",
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

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_retry_telemetry_req_#{unique}",
        request_type: "test_retry_telemetry_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      Executor.execute!(request)

      # Should receive at least one retry event
      assert_received {:retry_event, %{attempt: _n}, %{mode: :same_node, type: :local}}
    end

    test "emits retry exhausted telemetry when all retries fail", %{
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      test_pid = self()
      handler_id = "test-retry-exhausted-handler-#{unique}"

      :telemetry.attach(
        handler_id,
        [:phoenix_gen_api, :executor, :retry, :exhausted],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:retry_exhausted, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      config = %FunConfig{
        request_type: "test_retry_exhausted_tele_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :always_fail, [counter]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:same_node, 2}
      }

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_retry_exhausted_tele_req_#{unique}",
        request_type: "test_retry_exhausted_tele_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false

      # Should receive the exhausted event
      assert_received {:retry_exhausted, metadata}
      assert metadata.request_id == "test_retry_exhausted_tele_req_#{unique}"
      # Mode reflects the original configured retry value
      assert metadata.mode == {:same_node, 2}
    end

    test "does not emit retry exhausted when retries succeed", %{
      counter: counter,
      config_tracker: config_tracker,
      unique: unique
    } do
      test_pid = self()
      handler_id = "test-retry-no-exhausted-#{unique}"

      :telemetry.attach(
        handler_id,
        [:phoenix_gen_api, :executor, :retry, :exhausted],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :retry_exhausted_received)
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      config = %FunConfig{
        request_type: "test_no_exhausted_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :fail_then_succeed, [counter, 1]},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:same_node, 3}
      }

      track_config(config_tracker, config)

      request = %Request{
        request_id: "test_no_exhausted_req_#{unique}",
        request_type: "test_no_exhausted_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == true

      # Should NOT receive the exhausted event since retries succeeded
      refute_received :retry_exhausted_received
    end
  end

  # Test helper functions

  defp track_config(config_tracker, config) do
    Agent.update(config_tracker, fn list ->
      [{config.service, config.request_type} | list]
    end)

    ConfigDb.add(config)
  end

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
