defmodule PhoenixGenApi.TelemetryTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Telemetry
  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.RateLimiter
  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Structs.{Request, FunConfig}

  setup do
    # Clean ConfigDb before each test
    :ets.delete_all_objects(PhoenixGenApi.ConfigDb)

    # Reset rate limiter
    RateLimiter.update_config(%{global_limits: [], api_limits: []})
    RateLimiter.clear()

    :ok
  end

  describe "list_events/0" do
    test "returns a list of all telemetry event names" do
      events = Telemetry.list_events()

      assert is_list(events)
      assert length(events) > 0

      # Every event must be a list of atoms
      Enum.each(events, fn event ->
        assert is_list(event)

        Enum.each(event, fn segment ->
          assert is_atom(segment)
        end)
      end)
    end

    test "includes executor events" do
      events = Telemetry.list_events()

      assert [:phoenix_gen_api, :executor, :request, :start] in events
      assert [:phoenix_gen_api, :executor, :request, :stop] in events
      assert [:phoenix_gen_api, :executor, :request, :exception] in events
      assert [:phoenix_gen_api, :executor, :retry] in events
    end

    test "includes rate limiter events" do
      events = Telemetry.list_events()

      assert [:phoenix_gen_api, :rate_limiter, :check] in events
      assert [:phoenix_gen_api, :rate_limiter, :exceeded] in events
      assert [:phoenix_gen_api, :rate_limiter, :reset] in events
      assert [:phoenix_gen_api, :rate_limiter, :cleanup] in events
    end

    test "includes hook events" do
      events = Telemetry.list_events()

      assert [:phoenix_gen_api, :hook, :before, :start] in events
      assert [:phoenix_gen_api, :hook, :before, :stop] in events
      assert [:phoenix_gen_api, :hook, :before, :exception] in events
      assert [:phoenix_gen_api, :hook, :after, :start] in events
      assert [:phoenix_gen_api, :hook, :after, :stop] in events
      assert [:phoenix_gen_api, :hook, :after, :exception] in events
    end

    test "includes worker pool events" do
      events = Telemetry.list_events()

      assert [:phoenix_gen_api, :worker_pool, :task, :start] in events
      assert [:phoenix_gen_api, :worker_pool, :task, :stop] in events
      assert [:phoenix_gen_api, :worker_pool, :task, :exception] in events
      assert [:phoenix_gen_api, :worker_pool, :circuit_breaker, :open] in events
      assert [:phoenix_gen_api, :worker_pool, :circuit_breaker, :close] in events
    end

    test "includes config cache events" do
      events = Telemetry.list_events()

      assert [:phoenix_gen_api, :config, :pull, :start] in events
      assert [:phoenix_gen_api, :config, :pull, :stop] in events
      assert [:phoenix_gen_api, :config, :push] in events
      assert [:phoenix_gen_api, :config, :add] in events
      assert [:phoenix_gen_api, :config, :batch_add] in events
      assert [:phoenix_gen_api, :config, :delete] in events
      assert [:phoenix_gen_api, :config, :clear] in events
      assert [:phoenix_gen_api, :config, :disable] in events
      assert [:phoenix_gen_api, :config, :enable] in events
    end
  end

  describe "attach_all/3 and detach_all/1" do
    test "attaches a handler to all events and detaches cleanly" do
      test_pid = self()

      :ok =
        Telemetry.attach_all("test-all-handler", fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, measurements, metadata})
        end)

      # Trigger an event by adding a config
      config = valid_config(%{service: "AttachAllTest", request_type: "test_req"})
      ConfigDb.add(config)

      # Should receive at least one event
      assert_receive {:telemetry_event, _measurements, _metadata}, 1000

      # Detach and verify no more events
      :ok = Telemetry.detach_all("test-all-handler")

      # Add another config — should NOT trigger our handler
      config2 = valid_config(%{service: "AttachAllTest2", request_type: "test_req2"})
      ConfigDb.add(config2)

      refute_receive {:telemetry_event, _, _}, 200
    after
      Telemetry.detach_all("test-all-handler")
    end
  end

  describe "attach_executor/3" do
    test "attaches only to executor events" do
      test_pid = self()

      :ok =
        Telemetry.attach_executor("test-exec-handler", fn event,
                                                          measurements,
                                                          metadata,
                                                          _config ->
          send(test_pid, {:executor_event, event, measurements, metadata})
        end)

      on_exit(fn ->
        Telemetry.detach_all("test-exec-handler")
      end)

      # Trigger an executor event by executing a request
      config = valid_config(%{service: "ExecTelemetryTest", request_type: "exec_test"})
      ConfigDb.add(config)

      request = %Request{
        request_id: "exec_telemetry_req",
        request_type: "exec_test",
        service: "ExecTelemetryTest",
        user_id: "user_tel",
        device_id: "device_tel",
        args: %{}
      }

      Executor.execute!(request)

      # Should receive start and stop events
      assert_receive {:executor_event, [:phoenix_gen_api, :executor, :request, :start], _, _},
                     1000

      assert_receive {:executor_event, [:phoenix_gen_api, :executor, :request, :stop], _, _},
                     1000
    end
  end

  describe "attach_rate_limiter/3" do
    test "attaches only to rate limiter events" do
      test_pid = self()

      :ok =
        Telemetry.attach_rate_limiter("test-rl-handler", fn event,
                                                            measurements,
                                                            metadata,
                                                            _config ->
          send(test_pid, {:rl_event, event, measurements, metadata})
        end)

      on_exit(fn ->
        Telemetry.detach_all("test-rl-handler")
      end)

      # Configure a very low limit to trigger events
      RateLimiter.update_config(%{
        global_limits: [%{key: :user_id, max_requests: 1, window_ms: 10_000}],
        api_limits: []
      })

      request = %Request{
        request_id: "rl_telemetry_req",
        user_id: "rl_user",
        service: "rl_service",
        request_type: "rl_api"
      }

      # First check should succeed
      :ok = RateLimiter.check_rate_limit(request)
      assert_receive {:rl_event, [:phoenix_gen_api, :rate_limiter, :check], _, _}, 1000

      # Second check should be rate limited
      {:error, :rate_limited, _} = RateLimiter.check_rate_limit(request)
      assert_receive {:rl_event, [:phoenix_gen_api, :rate_limiter, :exceeded], _, _}, 1000
    end
  end

  describe "attach_config/3" do
    test "attaches only to config cache events" do
      test_pid = self()

      :ok =
        Telemetry.attach_config("test-cfg-handler", fn event, measurements, metadata, _config ->
          send(test_pid, {:cfg_event, event, measurements, metadata})
        end)

      on_exit(fn ->
        Telemetry.detach_all("test-cfg-handler")
      end)

      # Trigger a config add event
      config = valid_config(%{service: "CfgTelemetryTest", request_type: "cfg_test"})
      ConfigDb.add(config)

      assert_receive {:cfg_event, [:phoenix_gen_api, :config, :add], _, metadata}, 1000
      assert metadata.service == "CfgTelemetryTest"
      assert metadata.request_type == "cfg_test"
    end
  end

  describe "attach_many/4" do
    test "attaches to a custom list of events" do
      test_pid = self()

      events = [
        [:phoenix_gen_api, :config, :add],
        [:phoenix_gen_api, :config, :delete]
      ]

      :ok =
        Telemetry.attach_many("test-many-handler", events, fn event,
                                                              _measurements,
                                                              metadata,
                                                              _config ->
          send(test_pid, {:many_event, event, metadata})
        end)

      on_exit(fn ->
        Telemetry.detach_all("test-many-handler")
      end)

      config = valid_config(%{service: "ManyTest", request_type: "many_req", version: "1.0.0"})
      ConfigDb.add(config)

      assert_receive {:many_event, [:phoenix_gen_api, :config, :add], _}, 1000

      ConfigDb.delete("ManyTest", "many_req", "1.0.0")

      assert_receive {:many_event, [:phoenix_gen_api, :config, :delete], _}, 1000
    end
  end

  describe "attach_default_logger/1 and detach_default_logger/1" do
    test "attaches and detaches without errors" do
      :ok = Telemetry.attach_default_logger("test-default-logger")

      # Trigger some events — should not crash
      config = valid_config(%{service: "LoggerTest", request_type: "log_req"})
      ConfigDb.add(config)

      # Give logger time to process
      Process.sleep(50)

      :ok = Telemetry.detach_default_logger("test-default-logger")
    end
  end

  describe "execute/3" do
    test "emits a custom telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-execute-handler",
        [:phoenix_gen_api, :custom, :event],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:custom_event, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-execute-handler")
      end)

      :ok =
        Telemetry.execute(
          [:phoenix_gen_api, :custom, :event],
          %{count: 42},
          %{source: "test"}
        )

      assert_receive {:custom_event, %{count: 42}, %{source: "test"}}, 1000
    end
  end

  describe "span/3" do
    test "emits start and stop events around a function" do
      test_pid = self()

      :telemetry.attach(
        "test-span-start",
        [:phoenix_gen_api, :custom, :span, :start],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:span_start, metadata})
        end,
        %{}
      )

      :telemetry.attach(
        "test-span-stop",
        [:phoenix_gen_api, :custom, :span, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:span_stop, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-span-start")
        :telemetry.detach("test-span-stop")
      end)

      result =
        Telemetry.span(
          [:phoenix_gen_api, :custom, :span],
          %{operation: "test"},
          fn ->
            {"span result", %{operation: "test"}}
          end
        )

      assert result == "span result"
      assert_receive {:span_start, %{operation: "test"}}, 1000
      assert_receive {:span_stop, %{duration: _}, %{operation: "test"}}, 1000
    end

    test "emits exception event when function raises" do
      test_pid = self()

      :telemetry.attach(
        "test-span-exception",
        [:phoenix_gen_api, :custom, :span, :exception],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:span_exception, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-span-exception")
      end)

      assert_raise RuntimeError, fn ->
        Telemetry.span(
          [:phoenix_gen_api, :custom, :span],
          %{operation: "failing"},
          fn ->
            raise "span error"
          end
        )
      end

      assert_receive {:span_exception, %{operation: "failing"}}, 1000
    end
  end

  describe "executor request lifecycle telemetry" do
    test "emits start and stop events for successful sync execution" do
      test_pid = self()

      :telemetry.attach(
        "test-exec-lifecycle-start",
        [:phoenix_gen_api, :executor, :request, :start],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:req_start, measurements, metadata})
        end,
        %{}
      )

      :telemetry.attach(
        "test-exec-lifecycle-stop",
        [:phoenix_gen_api, :executor, :request, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:req_stop, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-exec-lifecycle-start")
        :telemetry.detach("test-exec-lifecycle-stop")
      end)

      config = valid_config(%{service: "LifecycleTest", request_type: "lifecycle_api"})
      ConfigDb.add(config)

      request = %Request{
        request_id: "lifecycle_req",
        request_type: "lifecycle_api",
        service: "LifecycleTest",
        user_id: "user_lifecycle",
        device_id: "device_lifecycle",
        args: %{}
      }

      Executor.execute!(request)

      # Verify start event
      assert_receive {:req_start, %{system_time: system_time}, metadata}, 1000
      assert is_integer(system_time)
      assert metadata.request_id == "lifecycle_req"
      assert metadata.request_type == "lifecycle_api"
      assert metadata.service == "LifecycleTest"
      assert metadata.user_id == "user_lifecycle"

      # Verify stop event
      assert_receive {:req_stop, %{duration_us: duration_us}, metadata}, 1000
      assert is_integer(duration_us)
      assert duration_us > 0
      assert metadata.request_id == "lifecycle_req"
      assert metadata.success == true
      assert metadata.async == false
    end

    test "emits exception event when execution fails with exception" do
      test_pid = self()

      :telemetry.attach(
        "test-exec-exception",
        [:phoenix_gen_api, :executor, :request, :exception],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:req_exception, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-exec-exception")
      end)

      # Create a config that will cause a PermissionDenied exception
      # Using {:arg, "user_id"} which checks if request.user_id matches request.args["user_id"]
      # When they don't match, PermissionDenied is raised before sync_call's rescue block
      config =
        valid_config(%{
          service: "ExceptionTest",
          request_type: "exception_api",
          check_permission: {:arg, "user_id"},
          arg_types: %{"user_id" => :string}
        })

      ConfigDb.add(config)

      request = %Request{
        request_id: "exception_req",
        request_type: "exception_api",
        service: "ExceptionTest",
        user_id: "user_a",
        device_id: "device_exception",
        args: %{"user_id" => "user_b"}
      }

      # This should raise a PermissionDenied exception, which is caught by execute!/1's rescue block
      # and re-raised after emitting the :exception telemetry event
      assert_raise PhoenixGenApi.Permission.PermissionDenied, fn ->
        Executor.execute!(request)
      end

      assert_receive {:req_exception, %{duration_us: duration_us}, metadata}, 1000
      assert is_integer(duration_us)
      assert metadata.request_id == "exception_req"
      assert metadata.kind == :error
      assert is_binary(metadata.reason)
    end
  end

  describe "config cache telemetry" do
    test "emits add event when adding a config" do
      test_pid = self()

      :telemetry.attach(
        "test-cfg-add",
        [:phoenix_gen_api, :config, :add],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:cfg_add, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-cfg-add")
      end)

      config = valid_config(%{service: "CfgAddTest", request_type: "add_api", version: "2.0.0"})
      ConfigDb.add(config)

      assert_receive {:cfg_add, %{}, metadata}, 1000
      assert metadata.service == "CfgAddTest"
      assert metadata.request_type == "add_api"
      assert metadata.version == "2.0.0"
    end

    test "emits batch_add event with count" do
      test_pid = self()

      :telemetry.attach(
        "test-cfg-batch",
        [:phoenix_gen_api, :config, :batch_add],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:cfg_batch, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-cfg-batch")
      end)

      configs = [
        valid_config(%{service: "BatchTelTest", request_type: "batch_api_1"}),
        valid_config(%{service: "BatchTelTest", request_type: "batch_api_2"}),
        valid_config(%{service: "BatchTelTest", request_type: "batch_api_3"})
      ]

      assert {:ok, 3} = ConfigDb.batch_add(configs)

      assert_receive {:cfg_batch, %{count: 3}, metadata}, 1000
      assert metadata.service == "BatchTelTest"
    end

    test "emits delete event when deleting a config" do
      test_pid = self()

      :telemetry.attach(
        "test-cfg-del",
        [:phoenix_gen_api, :config, :delete],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:cfg_del, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-cfg-del")
      end)

      config = valid_config(%{service: "CfgDelTest", request_type: "del_api", version: "1.0.0"})
      ConfigDb.add(config)
      ConfigDb.delete("CfgDelTest", "del_api", "1.0.0")

      assert_receive {:cfg_del, %{}, metadata}, 1000
      assert metadata.service == "CfgDelTest"
      assert metadata.request_type == "del_api"
      assert metadata.version == "1.0.0"
    end

    test "emits disable event when disabling a config" do
      test_pid = self()

      :telemetry.attach(
        "test-cfg-disable",
        [:phoenix_gen_api, :config, :disable],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:cfg_disable, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-cfg-disable")
      end)

      config =
        valid_config(%{service: "CfgDisableTest", request_type: "disable_api", version: "1.0.0"})

      ConfigDb.add(config)
      ConfigDb.disable("CfgDisableTest", "disable_api", "1.0.0")

      assert_receive {:cfg_disable, %{}, metadata}, 1000
      assert metadata.service == "CfgDisableTest"
      assert metadata.request_type == "disable_api"
      assert metadata.version == "1.0.0"
    end

    test "emits enable event when enabling a config" do
      test_pid = self()

      :telemetry.attach(
        "test-cfg-enable",
        [:phoenix_gen_api, :config, :enable],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:cfg_enable, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-cfg-enable")
      end)

      config =
        valid_config(%{service: "CfgEnableTest", request_type: "enable_api", version: "1.0.0"})

      ConfigDb.add(config)
      ConfigDb.disable("CfgEnableTest", "enable_api", "1.0.0")
      ConfigDb.enable("CfgEnableTest", "enable_api", "1.0.0")

      assert_receive {:cfg_enable, %{}, metadata}, 1000
      assert metadata.service == "CfgEnableTest"
      assert metadata.request_type == "enable_api"
      assert metadata.version == "1.0.0"
    end

    test "emits clear event when clearing all configs" do
      test_pid = self()

      :telemetry.attach(
        "test-cfg-clear",
        [:phoenix_gen_api, :config, :clear],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:cfg_clear, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-cfg-clear")
      end)

      config = valid_config(%{service: "CfgClearTest", request_type: "clear_api"})
      ConfigDb.add(config)
      ConfigDb.clear()

      assert_receive {:cfg_clear, %{}, metadata}, 1000
      assert metadata.service == :all
    end
  end

  describe "rate limiter telemetry" do
    test "emits check event with allowed status" do
      test_pid = self()

      :telemetry.attach(
        "test-rl-check",
        [:phoenix_gen_api, :rate_limiter, :check],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:rl_check, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-rl-check")
      end)

      RateLimiter.update_config(%{
        global_limits: [%{key: :user_id, max_requests: 100, window_ms: 60_000}],
        api_limits: []
      })

      request = %Request{
        request_id: "rl_check_req",
        user_id: "rl_check_user",
        service: "rl_check_service",
        request_type: "rl_check_api"
      }

      :ok = RateLimiter.check_rate_limit(request)

      assert_receive {:rl_check, %{duration_us: duration_us}, metadata}, 1000
      assert is_integer(duration_us)
      assert metadata.request_id == "rl_check_req"
      assert metadata.user_id == "rl_check_user"
      assert metadata.result == :ok
    end

    test "emits exceeded event when rate limit is exceeded" do
      test_pid = self()

      :telemetry.attach(
        "test-rl-exceeded",
        [:phoenix_gen_api, :rate_limiter, :exceeded],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:rl_exceeded, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-rl-exceeded")
      end)

      RateLimiter.update_config(%{
        global_limits: [%{key: :user_id, max_requests: 1, window_ms: 60_000}],
        api_limits: []
      })

      request = %Request{
        request_id: "rl_exceeded_req",
        user_id: "rl_exceeded_user",
        service: "rl_exceeded_service",
        request_type: "rl_exceeded_api"
      }

      # First request should pass
      :ok = RateLimiter.check_rate_limit(request)

      # Second request should be rate limited
      {:error, :rate_limited, _details} = RateLimiter.check_rate_limit(request)

      assert_receive {:rl_exceeded, %{retry_after_ms: retry_after_ms}, metadata}, 1000
      assert is_integer(retry_after_ms)
      assert retry_after_ms > 0
      assert metadata.key == "rl_exceeded_user"
      assert metadata.max_requests == 1
      assert metadata.current_requests == 1
    end

    test "emits reset event when rate limit is reset" do
      test_pid = self()

      :telemetry.attach(
        "test-rl-reset",
        [:phoenix_gen_api, :rate_limiter, :reset],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:rl_reset, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-rl-reset")
      end)

      RateLimiter.reset_rate_limit("reset_user", :global, :user_id)

      assert_receive {:rl_reset, %{}, metadata}, 1000
      assert metadata.key == "reset_user"
      assert metadata.scope == :global
      assert metadata.rate_limit_key == :user_id
    end
  end

  describe "hooks telemetry" do
    test "emits before hook start and stop events" do
      test_pid = self()

      :telemetry.attach(
        "test-hook-before-start",
        [:phoenix_gen_api, :hook, :before, :start],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:hook_before_start, measurements, metadata})
        end,
        %{}
      )

      :telemetry.attach(
        "test-hook-before-stop",
        [:phoenix_gen_api, :hook, :before, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:hook_before_stop, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-hook-before-start")
        :telemetry.detach("test-hook-before-stop")
      end)

      config =
        valid_config(%{
          service: "HookTelemetryTest",
          request_type: "hook_before_api",
          before_execute: {__MODULE__, :before_hook_ok}
        })

      ConfigDb.add(config)

      request = %Request{
        request_id: "hook_before_req",
        request_type: "hook_before_api",
        service: "HookTelemetryTest",
        user_id: "hook_user",
        device_id: "hook_device",
        args: %{}
      }

      Executor.execute!(request)

      assert_receive {:hook_before_start, %{system_time: _}, metadata}, 1000
      assert metadata.module == __MODULE__
      assert metadata.function == :before_hook_ok
      assert metadata.type == :before

      assert_receive {:hook_before_stop, %{duration_us: duration_us}, metadata}, 1000
      assert is_integer(duration_us)
      assert metadata.module == __MODULE__
      assert metadata.type == :before
    end

    test "emits after hook start and stop events" do
      test_pid = self()

      :telemetry.attach(
        "test-hook-after-start",
        [:phoenix_gen_api, :hook, :after, :start],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:hook_after_start, measurements, metadata})
        end,
        %{}
      )

      :telemetry.attach(
        "test-hook-after-stop",
        [:phoenix_gen_api, :hook, :after, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:hook_after_stop, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-hook-after-start")
        :telemetry.detach("test-hook-after-stop")
      end)

      config =
        valid_config(%{
          service: "HookAfterTelemetryTest",
          request_type: "hook_after_api",
          after_execute: {__MODULE__, :after_hook_ok}
        })

      assert :ok = ConfigDb.add(config)

      request = %Request{
        request_id: "hook_after_req",
        request_type: "hook_after_api",
        service: "HookAfterTelemetryTest",
        user_id: "hook_user",
        device_id: "hook_device",
        args: %{}
      }

      Executor.execute!(request)

      assert_receive {:hook_after_start, %{system_time: _}, metadata}, 1000
      assert metadata.module == __MODULE__
      assert metadata.function == :after_hook_ok
      assert metadata.type == :after

      assert_receive {:hook_after_stop, %{duration_us: duration_us}, metadata}, 1000
      assert is_integer(duration_us)
      assert metadata.module == __MODULE__
      assert metadata.type == :after
    end

    test "emits exception event when hook raises" do
      test_pid = self()

      :telemetry.attach(
        "test-hook-exception",
        [:phoenix_gen_api, :hook, :before, :exception],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:hook_exception, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-hook-exception")
      end)

      config =
        valid_config(%{
          service: "HookExceptionTest",
          request_type: "hook_exception_api",
          before_execute: {__MODULE__, :before_hook_failing}
        })

      ConfigDb.add(config)

      request = %Request{
        request_id: "hook_exception_req",
        request_type: "hook_exception_api",
        service: "HookExceptionTest",
        user_id: "hook_user",
        device_id: "hook_device",
        args: %{}
      }

      Executor.execute!(request)

      assert_receive {:hook_exception, %{duration_us: duration_us}, metadata}, 1000
      assert is_integer(duration_us)
      assert metadata.module == __MODULE__
      assert metadata.function == :before_hook_failing
      assert metadata.type == :before
      assert metadata.kind == :error
      assert is_binary(metadata.reason)
    end
  end

  describe "worker pool telemetry" do
    test "emits task start and stop events for successful tasks" do
      test_pid = self()

      :telemetry.attach(
        "test-wp-task-start",
        [:phoenix_gen_api, :worker_pool, :task, :start],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:wp_start, measurements, metadata})
        end,
        %{}
      )

      :telemetry.attach(
        "test-wp-task-stop",
        [:phoenix_gen_api, :worker_pool, :task, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:wp_stop, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-wp-task-start")
        :telemetry.detach("test-wp-task-stop")
      end)

      # Execute an async request which uses the worker pool
      config =
        valid_config(%{
          service: "WPTelemetryTest",
          request_type: "wp_async_api",
          response_type: :async
        })

      ConfigDb.add(config)

      request = %Request{
        request_id: "wp_telemetry_req",
        request_type: "wp_async_api",
        service: "WPTelemetryTest",
        user_id: "wp_user",
        device_id: "wp_device",
        args: %{}
      }

      Executor.execute!(request)

      assert_receive {:wp_start, %{system_time: _}, metadata}, 2000
      assert is_atom(metadata.pool_name)

      assert_receive {:wp_stop, %{duration_us: duration_us}, metadata}, 2000
      assert is_integer(duration_us)
      assert is_atom(metadata.pool_name)
    end

    test "emits task exception event for failing tasks" do
      test_pid = self()

      :telemetry.attach(
        "test-wp-task-exception",
        [:phoenix_gen_api, :worker_pool, :task, :exception],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:wp_exception, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-wp-task-exception")
      end)

      # Execute an async request with a failing function
      config =
        valid_config(%{
          service: "WPExceptionTest",
          request_type: "wp_exception_api",
          response_type: :async,
          mfa: {__MODULE__, :failing_function, []}
        })

      ConfigDb.add(config)

      request = %Request{
        request_id: "wp_exception_req",
        request_type: "wp_exception_api",
        service: "WPExceptionTest",
        user_id: "wp_user",
        device_id: "wp_device",
        args: %{}
      }

      Executor.execute!(request)

      assert_receive {:wp_exception, %{duration_us: duration_us}, metadata}, 2000
      assert is_integer(duration_us)
      assert is_atom(metadata.pool_name)
      assert metadata.kind == :error
      assert is_binary(metadata.reason)
    end
  end

  describe "retry telemetry" do
    test "emits retry events during local execution retry" do
      test_pid = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      :telemetry.attach(
        "test-retry-tel",
        [:phoenix_gen_api, :executor, :retry],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:retry_event, measurements, metadata})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-retry-tel")
        if Process.alive?(counter), do: Agent.stop(counter)
      end)

      config =
        valid_config(%{
          service: "RetryTelemetryTest",
          request_type: "retry_telemetry_api",
          retry: {:same_node, 2},
          mfa: {__MODULE__, :fail_then_succeed, [counter, 1]}
        })

      ConfigDb.add(config)

      request = %Request{
        request_id: "retry_telemetry_req",
        request_type: "retry_telemetry_api",
        service: "RetryTelemetryTest",
        user_id: "retry_user",
        device_id: "retry_device",
        args: %{}
      }

      Executor.execute!(request)

      assert_receive {:retry_event, %{attempt: attempt}, metadata}, 1000
      assert is_integer(attempt)
      assert metadata.mode == :same_node
      assert metadata.type == :local
    end
  end

  # Helper functions

  defp valid_config(overrides \\ %{}) do
    defaults = %{
      service: "Test",
      request_type: "test_request",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :sync_ok, []},
      arg_types: %{},
      arg_orders: [],
      response_type: :sync,
      check_permission: false,
      request_info: false,
      version: "0.0.0"
    }

    struct(FunConfig, Map.merge(defaults, overrides))
  end

  # Test hook functions
  def before_hook_ok(_request, fun_config) do
    {:ok, _request, fun_config}
  end

  def before_hook_failing(_request, _fun_config) do
    raise "hook intentionally failed"
  end

  def after_hook_ok(_request, _fun_config, result) do
    result
  end

  # Test executor functions
  def sync_ok do
    {:ok, "success"}
  end

  def failing_function do
    raise "intentional task failure"
  end

  def fail_then_succeed(counter, fail_count) do
    Agent.update(counter, &(&1 + 1))
    current = Agent.get(counter, & &1)

    if current <= fail_count do
      {:error, "fail on attempt #{current}"}
    else
      {:ok, "succeeded on attempt #{current}"}
    end
  end
end
