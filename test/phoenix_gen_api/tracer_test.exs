defmodule PhoenixGenApi.TracerTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.RateLimiter
  alias PhoenixGenApi.Structs.{FunConfig, Request, Response}
  alias PhoenixGenApi.Tracer
  alias PhoenixGenApi.Tracer.LogCapture

  require Logger

  setup do
    log_dir =
      Path.join(
        System.tmp_dir!(),
        "phoenix_gen_api_tracer_test_#{System.unique_integer([:positive])}"
      )

    :ok = Tracer.configure(log_dir: log_dir, max_file_bytes: 100_000, max_backup_files: 2)
    :ok = Tracer.clear()
    :ok = Tracer.set_enabled(true)

    on_exit(fn ->
      :ok = Tracer.clear()
      :ok = Tracer.set_enabled(false)
      File.rm_rf(log_dir)
    end)

    request = %Request{
      request_id: "tracer_req_1",
      request_type: "tracer_get_user",
      user_id: "tracer_user_1",
      device_id: "tracer_dev_1",
      service: "tracer_service",
      args: %{"id" => "tracer_user_1"}
    }

    {:ok, log_dir: log_dir, request: request}
  end

  describe "membership API" do
    test "enabled?/0 defaults to the config value and can be toggled at runtime" do
      assert is_boolean(Tracer.enabled?())
      :ok = Tracer.set_enabled(true)
      assert Tracer.enabled?()
      :ok = Tracer.set_enabled(false)
      refute Tracer.enabled?()
    end

    test "enable/disable request types and user ids, including lists" do
      :ok = Tracer.enable_request_type("get_user")
      :ok = Tracer.enable_request_type(["create_order", "delete_user"])

      assert Tracer.enabled_request_types()
             |> Enum.sort() == ["create_order", "delete_user", "get_user"]

      :ok = Tracer.disable_request_type("get_user")
      assert Tracer.enabled_request_types() |> Enum.sort() == ["create_order", "delete_user"]

      :ok = Tracer.enable_user_id("user_123")
      assert Tracer.enabled_user_ids() == ["user_123"]

      :ok = Tracer.disable_user_id(["user_123"])
      assert Tracer.enabled_user_ids() == []
    end

    test "invalid inputs are ignored" do
      assert :ok = Tracer.enable_request_type("")
      assert :ok = Tracer.enable_user_id(nil)
      assert Tracer.enabled_request_types() == []
      assert Tracer.enabled_user_ids() == []
    end

    test "clear/0 removes all enabled keys" do
      :ok = Tracer.enable_request_type("get_user")
      :ok = Tracer.enable_user_id("user_123")
      :ok = Tracer.clear()
      assert Tracer.enabled_request_types() == []
      assert Tracer.enabled_user_ids() == []
    end
  end

  describe "trace_request/1" do
    test "writes a request_start line to the request_type file", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("tracer_get_user")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")

      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "event=request_start"
      assert content =~ "request_type=tracer_get_user"
      assert content =~ "user_id=tracer_user_1"
      assert content =~ "service=tracer_service"
      assert content =~ "args="
      assert content =~ "request_id=tracer_req_1"
    end

    test "writes to the user_id file when the user is traced", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_user_id("tracer_user_1")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "user_id-tracer_user_1.log")
      assert File.exists?(path)
      assert File.read!(path) =~ "event=request_start"
    end

    test "writes one line per matching file when both request_type and user_id match", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("tracer_get_user")
      :ok = Tracer.enable_user_id("tracer_user_1")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      rt_path = Path.join(log_dir, "request_type-tracer_get_user.log")
      uid_path = Path.join(log_dir, "user_id-tracer_user_1.log")
      assert File.exists?(rt_path)
      assert File.exists?(uid_path)
      assert String.split(File.read!(rt_path), "\n", trim: true) |> length() == 1
      assert String.split(File.read!(uid_path), "\n", trim: true) |> length() == 1
    end

    test "writes nothing when tracing is disabled", %{log_dir: log_dir, request: request} do
      :ok = Tracer.enable_request_type("tracer_get_user")
      :ok = Tracer.set_enabled(false)
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      refute File.exists?(path)
    end

    test "writes nothing when the request does not match any enabled key", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("other_request_type")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      assert not File.exists?(log_dir) or File.ls!(log_dir) == []
    end
  end

  describe "trace_result/3" do
    test "writes a request_end line with success, async and duration", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("tracer_get_user")

      response = %Response{request_id: "tracer_req_1", success: true, result: %{"ok" => true}}
      :ok = Tracer.trace_result(request, response, 1234)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      content = File.read!(path)
      assert content =~ "event=request_end"
      assert content =~ "success=true"
      assert content =~ "async=false"
      assert content =~ "duration_us=1234"
      assert content =~ "error=nil"
    end

    test "records error and failed success for error results", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("tracer_get_user")

      response = %Response{request_id: "tracer_req_1", success: false, error: "boom"}
      :ok = Tracer.trace_result(request, response, 500)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      content = File.read!(path)
      assert content =~ "event=request_end"
      assert content =~ "success=false"
      assert content =~ "error=boom"
    end

    test "handles {:ok, :no_response} results", %{log_dir: log_dir, request: request} do
      :ok = Tracer.enable_request_type("tracer_get_user")
      :ok = Tracer.trace_result(request, {:ok, :no_response}, 10)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      content = File.read!(path)
      assert content =~ "event=request_end"
      assert content =~ "success=true"
      assert content =~ "async=true"
    end
  end

  describe "trace_permission/3" do
    test "writes an allowed line including the permission mode", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_user_id("tracer_user_1")

      config = %FunConfig{check_permission: {:arg, "user_id"}, version: "0.0.1"}
      :ok = Tracer.trace_permission(request, config, :allowed)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "user_id-tracer_user_1.log")
      content = File.read!(path)
      assert content =~ "event=permission"
      assert content =~ "permission=allowed"
      assert content =~ "permission_mode={:arg, \"user_id\"}"
    end

    test "writes a denied line including the callback mode", %{log_dir: log_dir, request: request} do
      :ok = Tracer.enable_request_type("tracer_get_user")

      config = %FunConfig{permission_callback: {MyMod, :check, []}, version: "0.0.1"}
      :ok = Tracer.trace_permission(request, config, :denied)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      content = File.read!(path)
      assert content =~ "event=permission"
      assert content =~ "permission=denied"
      assert content =~ "permission_mode={:callback, {MyMod, :check, []}}"
    end
  end

  describe "executor integration" do
    test "traces a full request lifecycle end-to-end", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_e2e_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_e2e_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :trace_e2e_fn, []},
        arg_types: %{"name" => :string},
        arg_orders: ["name"],
        response_type: :sync,
        check_permission: :any_authenticated,
        request_info: false
      }

      :ok = ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("tracer_e2e_service", request_type)
      end)

      :ok = Tracer.enable_request_type(request_type)

      request = %Request{
        request_id: "tracer_e2e_req_#{unique}",
        request_type: request_type,
        service: "tracer_e2e_service",
        user_id: "tracer_e2e_user",
        args: %{"name" => "Alice"}
      }

      result = Executor.execute!(request)
      assert result.success
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "event=request_start"
      assert content =~ "event=permission"
      assert content =~ "permission=allowed"
      assert content =~ "event=request_end"
      assert content =~ "success=true"
    end

    test "traces a permission denial via the executor", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_denied_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_denied_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :trace_e2e_fn, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        check_permission: {:arg, "user_id"},
        request_info: false
      }

      :ok = ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("tracer_denied_service", request_type)
      end)

      :ok = Tracer.enable_request_type(request_type)

      request = %Request{
        request_id: "tracer_denied_req_#{unique}",
        request_type: request_type,
        service: "tracer_denied_service",
        user_id: "tracer_denied_user",
        args: %{"user_id" => "someone_else"}
      }

      result = Executor.execute!(request)
      assert result.success == false
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "event=request_start"
      assert content =~ "event=permission"
      assert content =~ "permission=denied"
      assert content =~ "permission_mode={:arg, \"user_id\"}"
      assert content =~ "event=request_end"
    end
  end

  describe "async cross-process capture" do
    test "captures structured events from the async worker process", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_async_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_async_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :trace_async_fn, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async,
        check_permission: false,
        request_info: false
      }

      :ok = ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("tracer_async_service_#{unique}", request_type)
      end)

      :ok = Tracer.enable_request_type(request_type)

      request = %Request{
        request_id: "tracer_async_req_#{unique}",
        request_type: request_type,
        service: "tracer_async_service_#{unique}",
        user_id: "tracer_async_user",
        args: %{}
      }

      result = Executor.execute!(request)
      assert result.success
      assert result.async
      assert_receive {:async_call, %Response{success: true}}, 2000
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "event=request_start"
      assert content =~ "event=config_lookup"
      assert content =~ "event=arguments"
      assert content =~ "status=ok"
      assert content =~ "event=execution"
      assert content =~ "mode=local"
      assert content =~ "event=async"
      assert content =~ "status=queued"
      assert content =~ "event=request_end"
      assert content =~ "async=true"
    end
  end

  describe "executor failure-path trace events" do
    test "traces arguments errors and request_end for invalid args", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_bad_args_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_bad_args_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :trace_e2e_fn, []},
        arg_types: %{"name" => :num},
        arg_orders: ["name"],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      :ok = ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("tracer_bad_args_service", request_type)
      end)

      :ok = Tracer.enable_request_type(request_type)

      request = %Request{
        request_id: "tracer_bad_args_req_#{unique}",
        request_type: request_type,
        service: "tracer_bad_args_service",
        user_id: "tracer_bad_args_user",
        args: %{"name" => "not_a_number"}
      }

      assert_raise ArgumentError, fn -> Executor.execute!(request) end
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      content = File.read!(path)

      assert content =~ "event=arguments"
      assert content =~ "status=error"
      assert content =~ "event=request_end"
      assert content =~ "success=false"
    end

    test "traces hook_before and hook_after errors", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_hooks_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_hooks_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :trace_e2e_fn, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        before_execute: {__MODULE__, :trace_reject_before, []},
        after_execute: {__MODULE__, :trace_raise_after, []}
      }

      :ok = ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("tracer_hooks_service", request_type)
      end)

      :ok = Tracer.enable_request_type(request_type)

      request = %Request{
        request_id: "tracer_hooks_req_#{unique}",
        request_type: request_type,
        service: "tracer_hooks_service",
        user_id: "tracer_hooks_user",
        args: %{}
      }

      result = Executor.execute!(request)
      assert result.success == false
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      content = File.read!(path)

      assert content =~ "event=hook_before"
      assert content =~ "status=error"
      assert content =~ "event=hook_after"
      assert content =~ "event=request_end"
      assert content =~ "success=false"
    end

    test "traces a successful after hook as ok", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_after_ok_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_after_ok_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :trace_async_fn, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        after_execute: {__MODULE__, :trace_after_ok, []}
      }

      :ok = ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("tracer_after_ok_service", request_type)
      end)

      :ok = Tracer.enable_request_type(request_type)

      request = %Request{
        request_id: "tracer_after_ok_req_#{unique}",
        request_type: request_type,
        service: "tracer_after_ok_service",
        user_id: "tracer_after_ok_user",
        args: %{}
      }

      result = Executor.execute!(request)
      assert result.success
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      content = File.read!(path)

      assert content =~ "event=hook_after"
      assert content =~ "status=ok"
      assert content =~ "event=request_end"
      assert content =~ "success=true"
    end

    test "traces rate limit exceeded", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_rl_#{unique}"
      user_id = "tracer_rl_user_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_rl_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :trace_async_fn, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      :ok = ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("tracer_rl_service", request_type)
        RateLimiter.update_config(%{global_limits: [], api_limits: []})
      end)

      RateLimiter.update_config(%{
        global_limits: [%{key: :user_id, max_requests: 1, window_ms: 10_000}],
        api_limits: []
      })

      :ok = Tracer.enable_request_type(request_type)

      request = %Request{
        request_id: "tracer_rl_req_#{unique}",
        request_type: request_type,
        service: "tracer_rl_service",
        user_id: user_id,
        args: %{}
      }

      first = Executor.execute!(request)
      assert first.success

      second = Executor.execute!(request)
      assert second.success == false

      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      content = File.read!(path)

      assert content =~ "event=rate_limit"
      assert content =~ "status=limited"
      assert content =~ "event=request_end"
    end

    test "traces retry and retry_exhausted for a failing local retry", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_retry_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_retry_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :trace_e2e_fn, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: 2
      }

      :ok = ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("tracer_retry_service", request_type)
      end)

      :ok = Tracer.enable_request_type(request_type)

      # MFA that always errors so the local retry is exercised
      config = %{config | mfa: {__MODULE__, :trace_always_fail, []}}
      :ok = ConfigDb.update(config)

      request = %Request{
        request_id: "tracer_retry_req_#{unique}",
        request_type: request_type,
        service: "tracer_retry_service",
        user_id: "tracer_retry_user",
        args: %{}
      }

      result = Executor.execute!(request)
      assert result.success == false
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      content = File.read!(path)

      assert content =~ "event=retry"
      assert content =~ "type=local"
      assert content =~ "event=retry_exhausted"
      assert content =~ "event=request_end"
      assert content =~ "success=false"
    end

    test "traces rpc_fallback for an unreachable remote node", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_rpc_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_rpc_service",
        nodes: [:nonexistent_tracer_node@localhost],
        choose_node_mode: :random,
        timeout: 500,
        mfa: {__MODULE__, :trace_e2e_fn, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      :ok = ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("tracer_rpc_service", request_type)
      end)

      :ok = Tracer.enable_request_type(request_type)

      request = %Request{
        request_id: "tracer_rpc_req_#{unique}",
        request_type: request_type,
        service: "tracer_rpc_service",
        user_id: "tracer_rpc_user",
        args: %{}
      }

      result = Executor.execute!(request)
      assert result.success == false
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      content = File.read!(path)

      assert content =~ "event=rpc_fallback"
      assert content =~ "event=request_end"
      assert content =~ "success=false"
    end

    test "traces config_lookup disabled", %{log_dir: log_dir} do
      unique = System.unique_integer([:positive])
      request_type = "tracer_disabled_#{unique}"

      config = %FunConfig{
        request_type: request_type,
        service: "tracer_disabled_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :trace_async_fn, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      :ok = ConfigDb.add(config)
      :ok = ConfigDb.disable("tracer_disabled_service", request_type)

      on_exit(fn ->
        ConfigDb.delete("tracer_disabled_service", request_type)
      end)

      :ok = Tracer.enable_request_type(request_type)

      request = %Request{
        request_id: "tracer_disabled_req_#{unique}",
        request_type: request_type,
        service: "tracer_disabled_service",
        user_id: "tracer_disabled_user",
        args: %{}
      }

      result = Executor.execute!(request)
      assert result.success == false
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-#{request_type}.log")
      content = File.read!(path)

      assert content =~ "event=config_lookup"
      assert content =~ "status=disabled"
      assert content =~ "event=request_end"
      assert content =~ "success=false"
    end
  end

  describe "rotation" do
    test "rotates the trace file when it exceeds max_file_bytes", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.configure(max_file_bytes: 200, max_backup_files: 2)
      :ok = Tracer.enable_request_type("tracer_get_user")

      for _ <- 1..30 do
        :ok = Tracer.trace_request(request)
      end

      :ok = Tracer.flush()

      main = Path.join(log_dir, "request_type-tracer_get_user.log")
      assert File.exists?(main)

      rotated_count =
        Enum.count([".1", ".2"], fn suffix ->
          File.exists?(main <> suffix)
        end)

      assert rotated_count >= 1
    end
  end

  describe "disable/1 and edge cases" do
    test "disabling a request type stops writing new lines", %{log_dir: log_dir, request: request} do
      :ok = Tracer.enable_request_type("tracer_get_user")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.disable_request_type("tracer_get_user")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")

      assert File.exists?(path)
      assert String.split(File.read!(path), "\n", trim: true) |> length() == 1
    end

    test "sanitizes special characters in the traced key filename", %{
      log_dir: log_dir,
      request: request
    } do
      request = %{request | request_type: "get user/order:1"}
      :ok = Tracer.enable_request_type("get user/order:1")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-get_user_order_1.log")
      assert File.exists?(path)
      assert File.read!(path) =~ "request_type="
    end

    test "writes nothing for a traced key with empty content", %{log_dir: log_dir} do
      :ok = Tracer.enable_request_type("empty_rt")
      :ok = Tracer.trace_request(%Request{request_type: "empty_rt", user_id: nil})
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-empty_rt.log")
      assert File.exists?(path)
      assert File.read!(path) =~ "event=request_start"
      assert File.read!(path) =~ "user_id=nil"
    end
  end

  describe "status/0 and configure/1" do
    test "status/0 reports started flag, enabled keys, log_dir and max settings", %{
      log_dir: log_dir
    } do
      :ok = Tracer.enable_request_type("status_rt")
      :ok = Tracer.enable_user_id("status_uid")

      status = Tracer.status()
      assert status.started
      assert status.enabled
      assert status.request_types == ["status_rt"]
      assert status.user_ids == ["status_uid"]
      assert status.log_dir == log_dir
      assert is_integer(status.max_file_bytes)
      assert is_integer(status.max_backup_files)
      assert is_map(status.files)
    end

    test "status/0 tracks open trace files and their sizes", %{log_dir: log_dir, request: request} do
      :ok = Tracer.enable_request_type("tracer_get_user")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      status = Tracer.status()
      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      assert Map.has_key?(status.files, path)
      assert Map.get(status.files, path) > 0
    end

    test "configure/1 updates log_dir for subsequently opened files", %{
      log_dir: _log_dir,
      request: request
    } do
      new_dir =
        Path.join(
          System.tmp_dir!(),
          "phoenix_gen_api_tracer_cfg_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf(new_dir) end)

      :ok = Tracer.configure(log_dir: new_dir)
      :ok = Tracer.enable_request_type("tracer_get_user")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      path = Path.join(new_dir, "request_type-tracer_get_user.log")
      assert File.exists?(path)
    end
  end

  describe "full lifecycle" do
    test "writes request_start, permission and request_end lines in order", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("tracer_get_user")

      config = %FunConfig{check_permission: :any_authenticated, version: "0.0.1"}

      :ok = Tracer.trace_request(request)
      :ok = Tracer.trace_permission(request, config, :allowed)
      :ok = Tracer.trace_result(request, %Response{success: true, result: %{}}, 250)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")

      lines =
        path
        |> File.read!()
        |> String.split("\n", trim: true)

      assert length(lines) == 3
      assert Enum.at(lines, 0) =~ "event=request_start"
      assert Enum.at(lines, 1) =~ "event=permission"
      assert Enum.at(lines, 1) =~ "permission=allowed"
      assert Enum.at(lines, 2) =~ "event=request_end"
      assert Enum.at(lines, 2) =~ "duration_us=250"
    end
  end

  describe "config-based enabling" do
    test "loads enabled keys and settings from application config at startup" do
      log_dir =
        Path.join(
          System.tmp_dir!(),
          "phoenix_gen_api_tracer_config_#{System.unique_integer([:positive])}"
        )

      Application.put_env(:phoenix_gen_api, :tracer,
        enabled: true,
        log_dir: log_dir,
        request_types: "cfg_get_user",
        user_ids: ["cfg_user_1"]
      )

      # Restart the tracer so it re-reads the config
      GenServer.stop(PhoenixGenApi.Tracer)
      assert wait_until(fn -> Process.whereis(PhoenixGenApi.Tracer) != nil end)

      on_exit(fn ->
        Application.delete_env(:phoenix_gen_api, :tracer)
        GenServer.stop(PhoenixGenApi.Tracer)
        assert wait_until(fn -> Process.whereis(PhoenixGenApi.Tracer) != nil end)
        File.rm_rf(log_dir)
      end)

      assert PhoenixGenApi.Tracer.enabled?()

      assert PhoenixGenApi.Tracer.enabled_request_types() == ["cfg_get_user"]
      assert PhoenixGenApi.Tracer.enabled_user_ids() == ["cfg_user_1"]

      request = %Request{
        request_id: "cfg_req",
        request_type: "cfg_get_user",
        user_id: "cfg_user_1",
        service: "cfg_service",
        args: %{}
      }

      :ok = PhoenixGenApi.Tracer.trace_request(request)
      :ok = PhoenixGenApi.Tracer.flush()

      path = Path.join(log_dir, "request_type-cfg_get_user.log")
      assert File.exists?(path)
      assert File.read!(path) =~ "event=request_start"
    end
  end

  describe "trace context (begin_trace/end_trace/trace_event)" do
    test "begin_trace/1 writes request_start and trace_event/2 writes milestones", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("tracer_get_user")

      ctx = Tracer.begin_trace(request)
      assert ctx != nil

      :ok = Tracer.trace_event("config_lookup", %{"status" => "ok", "version" => "0.0.1"})
      :ok = Tracer.trace_event("rate_limit", %{"status" => "allowed"})
      :ok = Tracer.end_trace(ctx)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      content = File.read!(path)

      assert content =~ "event=request_start"
      assert content =~ "event=config_lookup"
      assert content =~ "status=ok"
      assert content =~ "version=0.0.1"
      assert content =~ "event=rate_limit"
      assert content =~ "status=allowed"
      assert content =~ "request_id=tracer_req_1"
      assert content =~ "request_type=tracer_get_user"
      assert content =~ "user_id=tracer_user_1"
    end

    test "end_trace/1 restores the process metadata", %{request: request} do
      Logger.reset_metadata(request_id: "pre-existing")
      :ok = Tracer.enable_request_type("tracer_get_user")

      ctx = Tracer.begin_trace(request)
      assert Logger.metadata()[:request_id] == "pre-existing"
      assert Logger.metadata()[:phoenix_gen_api_trace] != nil

      :ok = Tracer.end_trace(ctx)

      assert Logger.metadata()[:phoenix_gen_api_trace] == nil
      assert Logger.metadata()[:request_id] == "pre-existing"
    end

    test "begin_trace/1 returns nil for untraced requests and trace_event is a no-op", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("other_request_type")

      assert Tracer.begin_trace(request) == nil
      :ok = Tracer.trace_event("config_lookup", %{"status" => "ok"})
      :ok = Tracer.flush()

      assert not File.exists?(log_dir) or File.ls!(log_dir) == []
    end
  end

  describe "raw log capture" do
    test "captures Logger output emitted while a request is traced", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("tracer_get_user")

      ctx = Tracer.begin_trace(request)
      Logger.warning("[TracerTest] action happened")
      :ok = Tracer.end_trace(ctx)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      content = File.read!(path)

      assert content =~ "event=log"
      assert content =~ "level=warning"
      assert content =~ "message="
      assert content =~ "[TracerTest] action happened"
      assert content =~ "request_id=tracer_req_1"
    end

    test "captures report-style Logger messages", %{log_dir: log_dir, request: request} do
      :ok = Tracer.enable_request_type("tracer_get_user")

      ctx = Tracer.begin_trace(request)
      Logger.warning(%{foo: "bar"})
      :ok = Tracer.end_trace(ctx)
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      content = File.read!(path)

      assert content =~ "event=log"
      assert content =~ "level=warning"
      assert content =~ "message="
      assert content =~ "foo"
    end

    test "does not capture Logger output after end_trace/1", %{
      log_dir: log_dir,
      request: request
    } do
      :ok = Tracer.enable_request_type("tracer_get_user")

      ctx = Tracer.begin_trace(request)
      :ok = Tracer.end_trace(ctx)
      Logger.warning("[TracerTest] after trace ended")
      :ok = Tracer.flush()

      path = Path.join(log_dir, "request_type-tracer_get_user.log")
      content = File.read!(path)
      refute content =~ "[TracerTest] after trace ended"
    end

    test "does not capture logs for untraced requests", %{log_dir: log_dir, request: request} do
      :ok = Tracer.enable_request_type("other_request_type")

      ctx = Tracer.begin_trace(request)
      assert ctx == nil
      Logger.warning("[TracerTest] untraced")
      :ok = Tracer.flush()

      assert not File.exists?(log_dir) or File.ls!(log_dir) == []
    end
  end

  describe "logger level management" do
    test "enabling tracing raises the primary log level, disabling restores it" do
      :ok = Tracer.set_enabled(true)
      assert Logger.level() == :debug

      :ok = Tracer.set_enabled(false)
      assert Logger.level() == :warning
    end

    test "status/0 reports the capture level and current log level", %{log_dir: log_dir} do
      :ok = Tracer.set_enabled(true)

      status = Tracer.status()
      assert status.capture_level == :debug
      assert status.log_level == :debug
      assert status.log_dir == log_dir

      :ok = Tracer.set_enabled(false)
    end
  end

  describe "console suppression filter" do
    test "stops untraced low-level messages below the app level" do
      event = %{level: :debug, meta: %{phoenix_gen_api_trace: []}}
      assert LogCapture.console_filter(event, %{level: :warning}) == :stop
    end

    test "lets traced low-level messages through" do
      event = %{level: :debug, meta: %{phoenix_gen_api_trace: [{:request_type, "get_user"}]}}

      assert LogCapture.console_filter(event, %{level: :warning}) == event
    end

    test "lets messages at or above the app level through" do
      event = %{level: :warning, meta: %{phoenix_gen_api_trace: []}}
      assert LogCapture.console_filter(event, %{level: :warning}) == event

      event = %{level: :error, meta: %{phoenix_gen_api_trace: []}}
      assert LogCapture.console_filter(event, %{level: :warning}) == event
    end

    test "falls back to :ignore for unexpected events" do
      assert LogCapture.console_filter(:unexpected, %{}) == :ignore
    end
  end

  describe "PhoenixGenApi convenience functions" do
    test "enable/disable request types and user ids via the top-level module" do
      :ok = PhoenixGenApi.enable_trace_request_type("conv_rt")
      :ok = PhoenixGenApi.enable_trace_user_id("conv_uid")

      assert Tracer.enabled_request_types() == ["conv_rt"]
      assert Tracer.enabled_user_ids() == ["conv_uid"]

      :ok = PhoenixGenApi.disable_trace_request_type("conv_rt")
      :ok = PhoenixGenApi.disable_trace_user_id("conv_uid")

      assert Tracer.enabled_request_types() == []
      assert Tracer.enabled_user_ids() == []
    end

    test "tracer_status/0 exposes the tracer status" do
      status = PhoenixGenApi.tracer_status()
      assert status.started
      assert is_map(status.files)
    end
  end

  describe "LogCapture.log/2 direct handler tests" do
    setup do
      snapshot = %{
        request_id: "req_1",
        user_id: "user_1",
        device_id: "dev_1",
        request_type: "get_user",
        service: "svc",
        version: nil
      }

      {:ok, snapshot: snapshot}
    end

    defp traced_meta(snapshot, extra \\ %{}) do
      Map.merge(
        %{
          phoenix_gen_api_trace: [{:user_id, "user_1"}],
          phoenix_gen_api_trace_request: snapshot,
          pid: self()
        },
        extra
      )
    end

    test "captures a string message and forwards it to the tracer pid", %{snapshot: snapshot} do
      event = %{level: :warning, meta: traced_meta(snapshot), msg: {:warning, {:string, "hello world"}}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :debug})

      assert_receive {:trace_line, :user_id, "user_1", line}, 200
      assert line =~ "event=log"
      assert line =~ "level=warning"
      assert line =~ "hello world"
      assert line =~ "request_id=req_1"
    end

    test "captures a report message", %{snapshot: snapshot} do
      event = %{level: :info, meta: traced_meta(snapshot), msg: {:info, {:report, %{foo: "bar"}}}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :debug})

      assert_receive {:trace_line, :user_id, "user_1", line}, 200
      assert line =~ "foo"
    end

    test "captures a format/args message", %{snapshot: snapshot} do
      event = %{level: :info, meta: traced_meta(snapshot), msg: {:info, {:format, "value=~s", ["x"]}}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :debug})

      assert_receive {:trace_line, :user_id, "user_1", line}, 200
      assert line =~ "value=x"
    end

    test "captures an arbitrary (other) message format", %{snapshot: snapshot} do
      event = %{level: :info, meta: traced_meta(snapshot), msg: {:info, :some_atom}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :debug})

      assert_receive {:trace_line, :user_id, "user_1", line}, 200
      assert line =~ "message=some_atom"
    end

    test "falls back to format_value when the chardata is invalid", %{snapshot: snapshot} do
      # 1_500_000 is an invalid Unicode codepoint, so IO.chardata_to_string raises
      event = %{level: :info, meta: traced_meta(snapshot), msg: {:info, {:string, [1_500_000]}}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :debug})

      assert_receive {:trace_line, :user_id, "user_1", line}, 200
      assert line =~ "message="
    end

    test "handles events without a :pid in meta by using the current process", %{snapshot: snapshot} do
      meta = traced_meta(snapshot, %{pid: nil})
      event = %{level: :info, meta: meta, msg: {:info, {:string, "no pid"}}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :debug})

      assert_receive {:trace_line, :user_id, "user_1", line}, 200
      assert line =~ "no pid"
    end

    test "formats mfa metadata as a string", %{snapshot: snapshot} do
      meta = traced_meta(snapshot, %{mfa: {MyApp, :do_thing, 2}})
      event = %{level: :info, meta: meta, msg: {:info, {:string, "with mfa"}}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :debug})

      assert_receive {:trace_line, :user_id, "user_1", line}, 200
      assert line =~ "mfa=MyApp.do_thing/2"
    end

    test "passes through non-tuple mfa metadata as-is", %{snapshot: snapshot} do
      meta = traced_meta(snapshot, %{mfa: "just a string"})
      event = %{level: :info, meta: meta, msg: {:info, {:string, "weird mfa"}}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :debug})

      assert_receive {:trace_line, :user_id, "user_1", line}, 200
      assert line =~ "just a string"
    end

    test "does not forward events below the capture level", %{snapshot: snapshot} do
      event = %{level: :debug, meta: traced_meta(snapshot), msg: {:debug, {:string, "debug msg"}}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :info})

      refute_receive {:trace_line, _, _, _}, 50
    end

    test "does not forward events for untraced processes" do
      event = %{level: :info, meta: %{pid: self()}, msg: {:info, {:string, "untraced"}}}

      assert :ok = LogCapture.log(event, %{tracer_pid: self(), level: :debug})

      refute_receive {:trace_line, _, _, _}, 50
    end

    test "returns :ok for unexpected event shapes" do
      assert :ok = LogCapture.log(:unexpected, %{})
    end
  end

  describe "edge-case API coverage" do
    test "disable_request_type/1 accepts a list" do
      :ok = Tracer.enable_request_type(["a_rt", "b_rt"])
      :ok = Tracer.disable_request_type(["a_rt", "b_rt"])
      assert Tracer.enabled_request_types() == []
    end

    test "disable_request_type/1 ignores invalid input" do
      assert :ok = Tracer.disable_request_type(nil)
      assert :ok = Tracer.disable_request_type("")
    end

    test "enable_user_id/1 accepts a list" do
      :ok = Tracer.enable_user_id(["u1", "u2"])
      assert Tracer.enabled_user_ids() |> Enum.sort() == ["u1", "u2"]
    end

    test "disable_user_id/1 ignores invalid input" do
      assert :ok = Tracer.disable_user_id(nil)
      assert :ok = Tracer.disable_user_id("")
    end

    test "set_enabled/1 normalizes string booleans" do
      :ok = Tracer.set_enabled("true")
      assert Tracer.enabled?()

      :ok = Tracer.set_enabled("false")
      refute Tracer.enabled?()

      :ok = Tracer.set_enabled("bogus")
      refute Tracer.enabled?()

      :ok = Tracer.set_enabled(true)
    end

    test "trace_request/1 ignores non-request arguments" do
      assert :ok = Tracer.trace_request(:not_a_request)
      assert :ok = Tracer.trace_request(%{})
    end

    test "trace_permission/3 ignores non-request arguments" do
      assert :ok = Tracer.trace_permission(:not_a_request, %FunConfig{}, :allowed)
      assert :ok = Tracer.trace_permission(%Request{}, %FunConfig{}, :bogus_result)
    end

    test "trace_result/3 ignores non-request arguments and records error/other results" do
      assert :ok = Tracer.trace_result(:not_a_request, %Response{}, 0)

      request = %Request{
        request_id: "edge_req",
        request_type: "edge_rt",
        user_id: "edge_user",
        service: "edge_service"
      }

      :ok = Tracer.enable_request_type("edge_rt")
      :ok = Tracer.trace_result(request, {:error, "boom"}, 5)
      :ok = Tracer.trace_result(request, "plain result", 6)
      :ok = Tracer.flush()
    end

    test "trace_result/3 is a no-op when the request is not traced" do
      :ok = Tracer.enable_request_type("some_other_rt")

      request = %Request{
        request_id: "untraced_req",
        request_type: "edge_rt",
        user_id: "edge_user",
        service: "edge_service"
      }

      :ok = Tracer.trace_result(request, %Response{success: true}, 1)
      :ok = Tracer.flush()
    end

    test "begin_trace/1 returns nil for non-request arguments" do
      assert Tracer.begin_trace(:not_a_request) == nil
    end

    test "trace_event/2 ignores invalid arguments" do
      assert :ok = Tracer.trace_event(123, %{})
      assert :ok = Tracer.trace_event("event", "not a map")
    end

    test "apply_trace_metadata/1 applies metadata for a traced request and no-ops otherwise" do
      request = %Request{
        request_id: "meta_req",
        request_type: "meta_rt",
        user_id: "meta_user",
        service: "meta_service"
      }

      :ok = Tracer.enable_request_type("meta_rt")
      :ok = Tracer.apply_trace_metadata(request)
      assert Logger.metadata()[:phoenix_gen_api_trace] != nil
      Logger.reset_metadata([])

      :ok = Tracer.clear()
      :ok = Tracer.enable_request_type("other")
      :ok = Tracer.apply_trace_metadata(request)
      assert Logger.metadata()[:phoenix_gen_api_trace] == nil

      assert :ok = Tracer.apply_trace_metadata(:not_a_request)
    end

    test "handle_info/2 ignores unknown messages" do
      send(PhoenixGenApi.Tracer, :some_unknown_message)
      Process.sleep(50)

      pid = Process.whereis(PhoenixGenApi.Tracer)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "format_value/1 handles booleans and floats" do
      assert Tracer.format_value(true) == "true"
      assert Tracer.format_value(false) == "false"
      assert Tracer.format_value(1.5) == "1.5"
      assert Tracer.format_value(42) == "42"
      assert Tracer.format_value(nil) == "nil"
    end

    test "write_line/1 reports and survives a failure to open the trace file", %{request: request} do
      bad_dir = Path.join(System.tmp_dir!(), "tracer_bad_dir_#{System.unique_integer([:positive])}")

      File.write!(bad_dir, "this is a file, not a dir")
      on_exit(fn -> File.rm(bad_dir) end)

      :ok = Tracer.configure(log_dir: bad_dir, max_file_bytes: 100_000)
      :ok = Tracer.enable_request_type("tracer_get_user")
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      # Recover by pointing at a valid directory
      good_dir =
        Path.join(System.tmp_dir!(), "tracer_good_dir_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(good_dir) end)

      :ok = Tracer.configure(log_dir: good_dir)
      :ok = Tracer.trace_request(request)
      :ok = Tracer.flush()

      path = Path.join(good_dir, "request_type-tracer_get_user.log")
      assert File.exists?(path)
    end
  end

  describe "config normalization" do
    test "normalizes nil/non-list keys and every binary log_level string via init/1" do
      for {level, expected} <- [
            {"debug", :debug},
            {"info", :info},
            {"notice", :notice},
            {"warn", :warning},
            {"warning", :warning},
            {"error", :error},
            {"critical", :critical},
            {"alert", :alert},
            {"emergency", :emergency},
            {"bogus_level", :debug},
            {:bogus_atom, :debug}
          ] do
        Application.put_env(:phoenix_gen_api, :tracer, [enabled: false, log_level: level])

        {:ok, state} = PhoenixGenApi.Tracer.init([])
        assert state.capture_level == expected

        :logger.remove_handler(PhoenixGenApi.Tracer.LogCapture)
        :logger.remove_handler_filter(:default, :phoenix_gen_api_trace_console)
      end

      Application.put_env(:phoenix_gen_api, :tracer,
        enabled: false,
        request_types: nil,
        user_ids: 123
      )

      {:ok, state} = PhoenixGenApi.Tracer.init([])
      assert state.capture_level == :debug
      assert PhoenixGenApi.Tracer.enabled_request_types() == []
      assert PhoenixGenApi.Tracer.enabled_user_ids() == []

      :logger.remove_handler(PhoenixGenApi.Tracer.LogCapture)
      :logger.remove_handler_filter(:default, :phoenix_gen_api_trace_console)
      Application.delete_env(:phoenix_gen_api, :tracer)

      on_exit(fn ->
        Application.delete_env(:phoenix_gen_api, :tracer)
        # Space this restart from earlier ones to stay inside the supervisor
        # restart intensity window, then re-attach the real tracer's handler.
        Process.sleep(5500)
        GenServer.stop(PhoenixGenApi.Tracer)
        assert wait_until(fn -> Process.whereis(PhoenixGenApi.Tracer) != nil end)
      end)
    end
  end

  defp wait_until(fun, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait = fn do_wait ->
      cond do
        fun.() ->
          true

        System.monotonic_time(:millisecond) > deadline ->
          false

        true ->
          Process.sleep(10)
          do_wait.(do_wait)
      end
    end

    do_wait.(do_wait)
  end

  def trace_e2e_fn(%{"name" => name}), do: {:ok, %{echo: name}}

  def trace_e2e_fn(_), do: {:ok, %{}}

  def trace_async_fn do
    {:ok, %{done: true}}
  end

  def trace_always_fail do
    {:error, "intentional trace failure"}
  end

  def trace_reject_before(request, fun_config) do
    {:error, "rejected"}
  end

  def trace_raise_after(request, fun_config, response) do
    raise "intentional after hook failure"
  end

  def trace_after_ok(request, fun_config, response) do
    %{response | result: "modified by after hook"}
  end
end
