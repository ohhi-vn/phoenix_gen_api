defmodule PhoenixGenApi.ExecutorCoverageTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.Structs.{FunConfig, Request}
  alias PhoenixGenApi.WorkerPool.WorkerPoolSupervisor

  setup do
    unique = System.unique_integer([:positive])
    {:ok, config_tracker} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      configs_to_clean =
        if Process.alive?(config_tracker) do
          Agent.get(config_tracker, & &1)
        else
          []
        end

      Enum.each(configs_to_clean, fn {service, request_type} ->
        ConfigDb.delete(service, request_type)
      end)

      if Process.alive?(config_tracker), do: Agent.stop(config_tracker)
    end)

    {:ok, unique: unique, config_tracker: config_tracker}
  end

  describe "telemetry" do
    test "attach_telemetry attaches start/stop/exception handlers", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      handler_id = "coverage-telemetry-#{unique}"
      Executor.attach_telemetry(handler_id, fn _, _, _, _ -> :ok end)
      on_exit(fn -> Executor.detach_telemetry(handler_id) end)

      request = request(unique, "coverage_attach_telemetry")
      add_config(config_tracker, base_config(unique, "coverage_attach_telemetry"))

      result = Executor.execute!(request)

      assert result.success == true
    end
  end

  describe "response_type handling" do
    test "unsupported response_type returns error", %{unique: unique} do
      request = request(unique, "coverage_bad_response_type")

      config = %FunConfig{
        request_type: "coverage_bad_response_type_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :ok_fun, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :bogus,
        check_permission: false,
        request_info: false
      }

      result = Executor.execute_with_config!(request, config)

      assert result.success == false
      assert result.error =~ "unsupported response type"
    end
  end

  describe "permission" do
    test "remote permission node selection failure returns permission denied", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_perm_node_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: {__MODULE__, :node_resolver_fail, []},
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :ok_fun, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        permission_callback: {__MODULE__, :perm_callback, []},
        request_info: false
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_perm_node"))

      assert result.success == false
      assert result.error == "Permission denied"
    end
  end

  describe "rate limiter" do
    test "rate limiter service error returns service unavailable", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      add_config(config_tracker, base_config(unique, "coverage_rate_limiter_error"))

      with_env(:rate_limiter, [timeout: :bogus, fail_open: false], fn ->
        result = Executor.execute!(request(unique, "coverage_rate_limiter_error"))

        assert result.success == false
        assert result.error == "Rate limit service unavailable"
        assert result.can_retry == true
      end)
    end
  end

  describe "sync_call error handling" do
    test "sync_call rescues argument conversion errors", %{unique: unique} do
      config = %FunConfig{
        request_type: "coverage_sync_rescue_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :ok_fun, []},
        arg_types: %{"name" => :string},
        arg_orders: ["name"],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      request = %Request{
        request_id: "coverage_sync_rescue_req_#{unique}",
        request_type: "coverage_sync_rescue_#{unique}",
        service: "coverage_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.sync_call(request, config)

      assert result.success == false
      assert result.error == "Internal Server Error"
    end

    test "sync_call returns error for MFA not allowed by denylist", %{unique: unique} do
      request = request(unique, "coverage_mfa_not_allowed")

      config = %FunConfig{
        request_type: "coverage_mfa_not_allowed_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {:os, :cmd, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      result = Executor.sync_call(request, config)

      assert result.success == false
      assert result.error == "Internal Server Error"
    end

    test "execute returns error when MFA is not exported", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_mfa_not_exported_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :nonexistent_fun, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_mfa_not_exported"))

      assert result.success == false
      assert result.error == "Internal Server Error"
    end
  end

  describe "local execution" do
    test "local execution fails when the task is killed after the timeout", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_local_timeout_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 100,
        mfa: {__MODULE__, :trap_and_sleep, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      with_env(:detail_error, true, fn ->
        result = Executor.execute!(request(unique, "coverage_local_timeout"))

        assert result.success == false
        assert result.error =~ "local execution failed"
      end)
    end

    test "local execution returns failure when the task exits abnormally", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_local_failed_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :raise_fun, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      with_env(:detail_error, true, fn ->
        with_trap_exit(fn ->
          result = Executor.execute!(request(unique, "coverage_local_failed"))

          assert result.success == false
          assert result.error =~ "local execution failed"
          assert result.error =~ "boom"
        end)
      end)
    end
  end

  describe "node selection" do
    test "node selection failure returns error", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_node_select_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: {__MODULE__, :node_resolver_fail, []},
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :remote_function, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      with_env(:detail_error, true, fn ->
        result = Executor.execute!(request(unique, "coverage_node_select"))

        assert result.success == false
        assert result.error =~ "node selection failed"
      end)
    end
  end

  describe "remote retry" do
    test "same_node remote retry exhausts all attempts", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_retry_same_node_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: [:nonexistent_node@localhost],
        choose_node_mode: :random,
        timeout: 1000,
        mfa: {__MODULE__, :remote_function, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:same_node, 2}
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_retry_same_node"))

      assert result.success == false
    end

    test "all_nodes remote retry exhausts all attempts", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_retry_all_nodes_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: [:nonexistent_node@localhost],
        choose_node_mode: :random,
        timeout: 1000,
        mfa: {__MODULE__, :remote_function, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:all_nodes, 2}
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_retry_all_nodes"))

      assert result.success == false
    end

    test "all_nodes retry falls back to empty nodes when resolution errors", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      {:ok, resolver} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(resolver), do: Agent.stop(resolver) end)

      config = %FunConfig{
        request_type: "coverage_retry_resolver_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: {__MODULE__, :node_resolver_agent, [resolver]},
        choose_node_mode: :random,
        timeout: 1000,
        mfa: {__MODULE__, :remote_function, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:all_nodes, 2}
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_retry_resolver"))

      assert result.success == false
    end

    test "remote execution succeeds when rpc succeeds", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_remote_success_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: [node()],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :remote_function, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: {:same_node, 1}
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_remote_success"))

      assert result.success == true
      assert result.result == "remote result"
    end

    test "rpc timeout uses infinity timeout", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_rpc_infinity_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: [node()],
        choose_node_mode: :random,
        timeout: :infinity,
        mfa: {__MODULE__, :remote_function, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_rpc_infinity"))

      assert result.success == true
      assert result.result == "remote result"
    end

    test "rpc timeout defaults to default when timeout is invalid", %{unique: unique} do
      request = request(unique, "coverage_rpc_default")

      config = %FunConfig{
        request_type: "coverage_rpc_default_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: [node()],
        choose_node_mode: :random,
        timeout: 0,
        mfa: {__MODULE__, :remote_function, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      result = Executor.sync_call(request, config)

      assert result.success == true
      assert result.result == "remote result"
    end

    test "rpc timeout triggers fallback to remaining nodes", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_rpc_timeout_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: [node()],
        choose_node_mode: :random,
        timeout: 100,
        mfa: {__MODULE__, :slow_remote, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      with_env(:detail_error, true, fn ->
        result = Executor.execute!(request(unique, "coverage_rpc_timeout"))

        assert result.success == false
        assert result.error =~ ":timeout"
      end)
    end

    test "rpc exit triggers fallback to remaining nodes", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_rpc_exit_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: [node()],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :exit_remote, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      with_env(:detail_error, true, fn ->
        result = Executor.execute!(request(unique, "coverage_rpc_exit"))

        assert result.success == false
        assert result.error =~ ":rpc_exit"
      end)
    end
  end

  describe "call result handling" do
    test "three tuple error is retryable and yields unexpected result", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_error3_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :error3, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: 2
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_error3"))

      assert result.success == false
      assert result.error == "Unexpected execution result"
    end
  end

  describe "detail_error" do
    test "exposes internal error details when detail_error is enabled", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_detail_error_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :error2, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      with_env(:detail_error, true, fn ->
        result = Executor.execute!(request(unique, "coverage_detail_error"))

        assert result.success == false
        assert result.error =~ "Internal Server Error:"
      end)
    end
  end

  describe "execute_with_timeout!/2" do
    test "returns the result on success", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      add_config(config_tracker, base_config(unique, "coverage_timeout_ok"))

      result = Executor.execute_with_timeout!(request(unique, "coverage_timeout_ok"), 5000)

      assert result.success == true
    end

    test "returns failure when the execution task exits", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_timeout_exit_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :raise_fun, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      with_trap_exit(fn ->
        result = Executor.execute_with_timeout!(request(unique, "coverage_timeout_exit"), 5000)

        assert result.success == false
        assert result.error =~ "Request failed:"
      end)
    end
  end

  describe "stream_call" do
    test "returns init response and reports stream errors", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_stream_error_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :stream_error_fun, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :stream,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_stream_error"))

      assert result.success == true
      assert result.async == true
      assert result.result == :init

      assert_receive {:stream_started, request_id, pid}, 2000
      assert request_id == request(unique, "coverage_stream_error").request_id
      assert is_pid(pid)

      assert_receive {:stream_response, response}, 2000
      assert response.success == false
    end

    test "times out and stops the stream when it stays alive", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      config = %FunConfig{
        request_type: "coverage_stream_timeout_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 100,
        mfa: {__MODULE__, :stream_fun, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :stream,
        check_permission: false,
        request_info: false
      }

      add_config(config_tracker, config)

      result = Executor.execute!(request(unique, "coverage_stream_timeout"))

      assert result.success == true
      assert result.result == :init

      assert_receive {:stream_started, _request_id, pid}, 2000
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 3000
    end

    test "reports failure when the stream task raises", %{unique: unique} do
      request = request(unique, "coverage_stream_raise")

      config = %FunConfig{
        request_type: "coverage_stream_raise_#{unique}",
        service: "coverage_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: nil,
        mfa: {__MODULE__, :stream_fun, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :stream,
        check_permission: false,
        request_info: false
      }

      result = Executor.execute_with_config!(request, config)

      assert result.success == true
      assert result.result == :init

      assert_receive {:stream_started, _request_id, pid}, 2000
      on_exit(fn -> if Process.alive?(pid), do: StreamCall.stop(pid) end)

      assert_receive {:stream_response, %{success: false} = response}, 2000
      assert response.success == false
    end
  end

  describe "worker pool queue full" do
    test "async_call returns service unavailable when the pool queue is full", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      try do
        replace_async_pool(1, 0)

        config = %FunConfig{
          request_type: "coverage_async_queue_#{unique}",
          service: "coverage_service_#{unique}",
          nodes: :local,
          choose_node_mode: :random,
          timeout: 5000,
          mfa: {__MODULE__, :ok_fun, []},
          arg_types: nil,
          arg_orders: [],
          response_type: :async,
          check_permission: false,
          request_info: false
        }

        add_config(config_tracker, config)

        :ok = PhoenixGenApi.WorkerPool.execute_async(:async_pool, fn -> Process.sleep(1000) end)

        result = Executor.execute!(request(unique, "coverage_async_queue"))

        assert result.success == false
        assert result.error =~ "Service temporarily unavailable"
        assert result.can_retry == true
      after
        restore_async_pool()
      end
    end

    test "stream_call returns service unavailable when the pool queue is full", %{
      unique: unique,
      config_tracker: config_tracker
    } do
      try do
        replace_async_pool(1, 0)

        config = %FunConfig{
          request_type: "coverage_stream_queue_#{unique}",
          service: "coverage_service_#{unique}",
          nodes: :local,
          choose_node_mode: :random,
          timeout: 5000,
          mfa: {__MODULE__, :stream_fun, []},
          arg_types: nil,
          arg_orders: [],
          response_type: :stream,
          check_permission: false,
          request_info: false
        }

        add_config(config_tracker, config)

        :ok = PhoenixGenApi.WorkerPool.execute_async(:async_pool, fn -> Process.sleep(1000) end)

        result = Executor.execute!(request(unique, "coverage_stream_queue"))

        assert result.success == false
        assert result.error =~ "Service temporarily unavailable"
        assert result.can_retry == true
      after
        restore_async_pool()
      end
    end
  end

  # --- helpers ---

  defp request(unique, type) do
    %Request{
      request_id: "#{type}_req_#{unique}",
      request_type: "#{type}_#{unique}",
      service: "coverage_service_#{unique}",
      user_id: "user_123",
      device_id: "device_456",
      args: %{}
    }
  end

  defp base_config(unique, type) do
    %FunConfig{
      request_type: "#{type}_#{unique}",
      service: "coverage_service_#{unique}",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :ok_fun, []},
      arg_types: nil,
      arg_orders: [],
      response_type: :sync,
      check_permission: false,
      request_info: false
    }
  end

  defp add_config(config_tracker, config) do
    Agent.update(config_tracker, fn list ->
      [{config.service, config.request_type} | list]
    end)

    assert :ok = ConfigDb.add(config)
  end

  defp with_env(key, value, fun) do
    original = Application.get_env(:phoenix_gen_api, key)

    Application.put_env(:phoenix_gen_api, key, value)

    try do
      fun.()
    after
      if is_nil(original) do
        Application.delete_env(:phoenix_gen_api, key)
      else
        Application.put_env(:phoenix_gen_api, key, original)
      end
    end
  end

  defp with_trap_exit(fun) do
    original = Process.flag(:trap_exit, true)

    try do
      fun.()
    after
      Process.flag(:trap_exit, original)
      flush_exit_messages()
    end
  end

  defp flush_exit_messages do
    receive do
      {:EXIT, _, _} -> flush_exit_messages()
    after
      0 -> :ok
    end
  end

  defp replace_async_pool(pool_size, max_queue_size) do
    sup = WorkerPoolSupervisor
    delete_pool_child(sup, :async_pool_coverage)
    delete_pool_child(sup, :async_pool)

    {:ok, _pid} =
      Supervisor.start_child(sup, %{
        id: :async_pool_coverage,
        start:
          {PhoenixGenApi.WorkerPool, :start_link,
           [
             [
               name: :async_pool,
               pool_size: pool_size,
               max_queue_size: max_queue_size,
               task_timeout: 5000
             ]
           ]}
      })

    :ok
  end

  defp restore_async_pool do
    sup = WorkerPoolSupervisor
    delete_pool_child(sup, :async_pool_coverage)

    {:ok, _pid} =
      Supervisor.start_child(sup, %{
        id: :async_pool,
        start:
          {PhoenixGenApi.WorkerPool, :start_link,
           [[name: :async_pool, pool_size: 1000, max_queue_size: 10_000]]}
      })

    :ok
  end

  defp delete_pool_child(sup, id) do
    case Supervisor.terminate_child(sup, id) do
      :ok ->
        case Supervisor.delete_child(sup, id) do
          :ok -> :ok
          {:error, _reason} -> :ok
        end

      {:error, :not_found} ->
        :ok
    end
  end

  # --- MFA helpers ---

  def ok_fun, do: {:ok, "success"}
  def raise_fun, do: raise("boom")

  def trap_and_sleep do
    Process.flag(:trap_exit, true)
    Process.sleep(6000)
    :ok
  end

  def error3, do: {:error, :timeout, %{message: "detail"}}
  def error2, do: {:error, "boom"}

  def slow_remote,
    do:
      (
        Process.sleep(1500)
        :ok
      )

  def exit_remote, do: exit(:boom)
  def remote_function, do: {:ok, "remote result"}
  def node_resolver_fail, do: :error

  def node_resolver_agent(agent) do
    n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
    if n == 0, do: [:nonexistent_node@localhost], else: :error
  end

  def stream_fun, do: {:ok, :init}
  def stream_error_fun, do: {:error, "stream boom"}
  def perm_callback, do: :allow
end
