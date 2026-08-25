defprotocol PhoenixGenApiTest.JSON.Encoder do
  @doc "Test protocol standing in for a JSON library encoder"
  def encode(data, opts)
end

defmodule PhoenixGenApiTest.ChannelBehaviour do
  @callback handle_in(String.t(), map(), map()) :: term()
  @callback handle_info(term(), map()) :: term()
end

defmodule PhoenixGenApiTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.ConfigFailed
  alias PhoenixGenApi.ConfigReceiver
  alias PhoenixGenApi.StreamCall
  alias PhoenixGenApi.Structs.{FunConfig, PushConfig, Request, Response}

  @compile {:no_warn_undefined, PhoenixGenApiTest.Channel}
  @compile {:no_warn_undefined, PhoenixGenApiTest.ChannelNoOverride}
  @compile {:no_warn_undefined, PhoenixGenApiTest.ChannelNoVerified}
  @compile {:no_warn_undefined, PhoenixGenApiTest.CustomEventChannel}

  setup_all do
    Application.put_env(:phoenix, :json_library, PhoenixGenApiTest.JSON)

    Enum.each(
      [
        {PhoenixGenApiTest.Channel, ""},
        {PhoenixGenApiTest.ChannelNoOverride, ", override_user_id: false"},
        {PhoenixGenApiTest.ChannelNoVerified, ", require_verified_user_id: false"},
        {PhoenixGenApiTest.CustomEventChannel, ", event: \"custom_event\""}
      ],
      fn {module, opts} -> compile_channel!(module, opts) end
    )

    on_exit(fn -> Application.delete_env(:phoenix, :json_library) end)
    :ok
  end

  setup do
    :ok = PhoenixGenApi.Tracer.clear()
    :ok = PhoenixGenApi.Tracer.set_enabled(false)
    :ok
  end

  defp unique do
    System.unique_integer([:positive])
  end

  defp register_config(request_type, opts \\ []) do
    config = %FunConfig{
      request_type: request_type,
      service: "test_service",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: Keyword.get(opts, :mfa, {__MODULE__, :echo_fn, []}),
      arg_types: Keyword.get(opts, :arg_types, %{}),
      arg_orders: Keyword.get(opts, :arg_orders, []),
      response_type: Keyword.get(opts, :response_type, :sync),
      check_permission: Keyword.get(opts, :check_permission, false),
      request_info: Keyword.get(opts, :request_info, false)
    }

    ConfigDb.add(config)

    on_exit(fn ->
      ConfigDb.delete("test_service", request_type)
    end)
  end

  defp compile_channel!(module_name, opts_code) do
    code = """
    defmodule #{inspect(module_name)} do
      @behaviour PhoenixGenApiTest.ChannelBehaviour

      use PhoenixGenApi#{opts_code}

      def push(socket, event, payload) do
        send(socket.ref, {:pushed, event, payload})
        socket
      end
    end
    """

    Code.compile_string(code)
    module_name
  end

  describe "stop_stream/1" do
    test "stops stream with pid" do
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

      receive do
        {:stream_response, _} -> :ok
      after
        1000 -> :ok
      end

      assert :ok = PhoenixGenApi.stop_stream(pid)

      receive do
        {:stream_response, response} ->
          assert response.has_more == false
      after
        1000 -> :ok
      end
    end
  end

  describe "rate limit delegation" do
    test "check_rate_limit/1 returns :ok when no limits are configured" do
      request = %Request{
        request_id: "rl_req_#{unique()}",
        request_type: "rl_unconfigured",
        service: "test_service",
        user_id: "user_1",
        device_id: "dev_1",
        args: %{}
      }

      assert :ok = PhoenixGenApi.check_rate_limit(request)
    end

    test "get_rate_limit_config/0 returns global and api keys" do
      config = PhoenixGenApi.get_rate_limit_config()
      assert is_list(config.global)
      assert is_list(config.api)
    end

    test "get_global_limits/0 returns a list" do
      assert is_list(PhoenixGenApi.get_global_limits())
    end

    test "set_global_limits/1 replaces limits and get_global_limits reflects it" do
      original = PhoenixGenApi.get_global_limits()
      key = "rl_test_key_#{unique()}"

      on_exit(fn -> PhoenixGenApi.set_global_limits(original) end)

      assert :ok =
               PhoenixGenApi.set_global_limits([%{key: key, max_requests: 5, window_ms: 1000}])

      limits = PhoenixGenApi.get_global_limits()
      assert Enum.any?(limits, &(&1.key == key))
    end

    test "add_global_limit/1 and remove_global_limit/1" do
      original = PhoenixGenApi.get_global_limits()
      key = "rl_add_key_#{unique()}"

      on_exit(fn -> PhoenixGenApi.set_global_limits(original) end)

      assert :ok =
               PhoenixGenApi.add_global_limit(%{key: key, max_requests: 10, window_ms: 60_000})

      assert Enum.any?(PhoenixGenApi.get_global_limits(), &(&1.key == key))

      assert :ok = PhoenixGenApi.remove_global_limit(key)
      refute Enum.any?(PhoenixGenApi.get_global_limits(), &(&1.key == key))
    end

    test "get_rate_limit_status/3 returns a list for a global scope" do
      key = "rl_status_user_#{unique()}"

      status = PhoenixGenApi.get_rate_limit_status(key, :global, :user_id)
      assert is_list(status)
    end

    test "reset_rate_limit/3 returns :ok" do
      key = "rl_reset_user_#{unique()}"
      assert :ok = PhoenixGenApi.reset_rate_limit(key, :global, :user_id)
    end

    test "update_rate_limit_config/1 returns :ok" do
      assert :ok = PhoenixGenApi.update_rate_limit_config(%{global_limits: []})
    end
  end

  describe "telemetry delegation" do
    test "attach_telemetry/3 attaches and detach_telemetry/1 detaches a handler" do
      handler_id = "pga_test_#{unique()}"
      parent = self()

      PhoenixGenApi.attach_telemetry(handler_id, fn event, _measurements, _metadata, _config ->
        send(parent, {:telemetry_event, event})
      end)

      on_exit(fn -> PhoenixGenApi.detach_telemetry(handler_id) end)

      request_type = "tel_delegate_#{unique()}"
      register_config(request_type)

      request = %Request{
        request_id: "tel_req_#{unique()}",
        request_type: request_type,
        service: "test_service",
        user_id: "user_1",
        device_id: "dev_1",
        args: %{}
      }

      PhoenixGenApi.Executor.execute!(request)

      assert_received {:telemetry_event, [:phoenix_gen_api, :executor, :request, :stop]}

      assert :ok = PhoenixGenApi.detach_telemetry(handler_id)
    end
  end

  describe "diagnostics delegation" do
    test "health_check/0 returns a report map" do
      report = PhoenixGenApi.health_check()
      assert report.node == Node.self()
      assert report.status in [:ok, :degraded, :error]
      assert report.checks.vm
      assert report.checks.phoenix_gen_api
    end

    test "statistics/0 returns a report map" do
      stats = PhoenixGenApi.statistics()
      assert stats.node == Node.self()
      assert stats.vm
      assert stats.phoenix_gen_api
    end

    test "debug_report/0 returns a report map" do
      report = PhoenixGenApi.debug_report()
      assert report.node == Node.self()
      assert is_list(report.processes)
      assert report.trace
    end

    test "call_flow/3 returns an error map for an unknown config" do
      flow = PhoenixGenApi.call_flow("unknown_service_#{unique()}", "get")
      assert flow.error
    end

    test "call_flow/3 returns a plan for a known config" do
      request_type = "flow_known_#{unique()}"
      register_config(request_type)

      flow = PhoenixGenApi.call_flow("test_service", request_type)
      assert flow.service == "test_service"
      assert flow.request_type == request_type
      assert is_list(flow.steps)
    end

    test "inspect_request/1 returns an execution plan or error" do
      plan = PhoenixGenApi.inspect_request(%{service: "unknown_#{unique()}", request_type: "get"})
      assert plan.error

      request_type = "inspect_known_#{unique()}"
      register_config(request_type)

      found =
        PhoenixGenApi.inspect_request(%{service: "test_service", request_type: request_type})

      assert found.request
      assert is_list(found.steps)
    end

    test "cluster_view/0 returns topology info" do
      view = PhoenixGenApi.cluster_view()
      assert view.self == Node.self()
      assert is_list(view.connected)
      assert view.node_selection
    end

    test "list_call_flows/0 returns a list" do
      request_type = "flows_list_#{unique()}"
      register_config(request_type)

      flows = PhoenixGenApi.list_call_flows()
      assert is_list(flows)
      assert Enum.any?(flows, &(&1.request_type == request_type))
    end

    test "trace_processes/2 and stop_trace/1 work with admin-gated tracing" do
      result = PhoenixGenApi.trace_processes([self()], trace_control_word: "test")
      assert match?({:ok, _}, result) or match?({:error, _}, result)

      stop_result = PhoenixGenApi.stop_trace(:all)
      assert stop_result == :ok or match?({:error, _}, stop_result)
    end

    test "trace_functions/2, stop_trace_functions/1 and trace_status/0 work" do
      result =
        PhoenixGenApi.trace_functions([{__MODULE__, :echo_fn, 0}], trace_control_word: "test")

      assert match?({:ok, _}, result) or match?({:error, _}, result)

      stop_result = PhoenixGenApi.stop_trace_functions()
      assert stop_result == :ok or match?({:error, _}, stop_result)

      assert PhoenixGenApi.trace_status() |> is_map()
    end
  end

  describe "config push delegation" do
    test "push_config/1 accepts a valid PushConfig" do
      request_type = "push_delegate_#{unique()}"

      fun_config = %FunConfig{
        request_type: request_type,
        service: "push_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {String, :upcase, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        version: "1.0.0"
      }

      push_config = %PushConfig{
        service: "push_service",
        nodes: [Node.self()],
        config_version: "1.0.0",
        fun_configs: [fun_config]
      }

      on_exit(fn ->
        ConfigReceiver.delete_pushed_service("push_service")
        ConfigDb.delete("push_service", request_type)
      end)

      assert {:ok, :accepted} = PhoenixGenApi.push_config(push_config)
      assert {:ok, :skipped, :version_matches} = PhoenixGenApi.push_config(push_config)
    end

    test "verify_config/2 returns :matched after a push" do
      request_type = "verify_delegate_#{unique()}"

      fun_config = %FunConfig{
        request_type: request_type,
        service: "verify_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {String, :upcase, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        version: "1.0.0"
      }

      push_config = %PushConfig{
        service: "verify_service",
        nodes: [Node.self()],
        config_version: "1.0.0",
        fun_configs: [fun_config]
      }

      on_exit(fn ->
        ConfigReceiver.delete_pushed_service("verify_service")
        ConfigDb.delete("verify_service", request_type)
      end)

      assert {:ok, :accepted} = PhoenixGenApi.push_config(push_config)
      assert {:ok, :matched} = PhoenixGenApi.verify_config("verify_service", "1.0.0")
      assert {:ok, :mismatch, "1.0.0"} = PhoenixGenApi.verify_config("verify_service", "2.0.0")
    end
  end

  describe "failed configs" do
    test "failed_configs/1 lists recorded entries with filters" do
      ConfigFailed.clear()

      entry =
        ConfigFailed.record(
          %FunConfig{service: "fc_service", request_type: "fc_rt"},
          "bad",
          :pull
        )

      assert entry.id
      assert Enum.any?(PhoenixGenApi.failed_configs(), &(&1.id == entry.id))
      assert Enum.any?(PhoenixGenApi.failed_configs(source: :pull), &(&1.id == entry.id))
      refute Enum.any?(PhoenixGenApi.failed_configs(source: :push), &(&1.id == entry.id))
      assert PhoenixGenApi.failed_configs(source: :push) |> is_list()

      :ok = PhoenixGenApi.clear_failed_configs()
      assert PhoenixGenApi.failed_configs() == []
    end

    test "cleanup_failed_configs/0 returns the number of removed entries" do
      ConfigFailed.clear()
      ConfigFailed.record(%FunConfig{service: "fc_c", request_type: "rt"}, "bad", :push)

      assert is_integer(PhoenixGenApi.cleanup_failed_configs())
      assert :ok = PhoenixGenApi.clear_failed_configs()
    end
  end

  describe "tracer delegation" do
    test "enable/disable trace request types and user ids via PhoenixGenApi" do
      rt = "pga_rt_#{unique()}"
      user = "pga_user_#{unique()}"

      assert :ok = PhoenixGenApi.enable_trace_request_type(rt)
      assert :ok = PhoenixGenApi.enable_trace_user_id(user)

      status = PhoenixGenApi.tracer_status()
      assert status.started

      assert :ok = PhoenixGenApi.disable_trace_request_type(rt)
      assert :ok = PhoenixGenApi.disable_trace_user_id(user)
      assert PhoenixGenApi.Tracer.enabled_request_types() == []
      assert PhoenixGenApi.Tracer.enabled_user_ids() == []
    end
  end

  describe "shell helpers" do
    test "rl_status/1 prints rate limit info" do
      output = capture_io(fn -> PhoenixGenApi.rl_status("user_#{unique()}") end)
      assert output =~ "Rate Limit Status"
      assert output =~ "Global Limits:"
    end

    test "rl_global/0 prints global limits" do
      output = capture_io(fn -> PhoenixGenApi.rl_global() end)
      assert output =~ "Global Rate Limits"
    end

    test "rl_global/1 sets limits and prints them" do
      original = PhoenixGenApi.get_global_limits()
      key = "rl_shell_key_#{unique()}"

      on_exit(fn -> PhoenixGenApi.set_global_limits(original) end)

      output =
        capture_io(fn ->
          PhoenixGenApi.rl_global([%{key: key, max_requests: 5, window_ms: 1000}])
        end)

      assert output =~ "Global rate limits updated"
      assert output =~ "#{key}"
    end

    test "rl_global(:add, limit) and rl_global(:remove, key)" do
      original = PhoenixGenApi.get_global_limits()
      key = "rl_shell_add_#{unique()}"

      on_exit(fn -> PhoenixGenApi.set_global_limits(original) end)

      add_output =
        capture_io(fn ->
          PhoenixGenApi.rl_global(:add, %{key: key, max_requests: 5, window_ms: 1000})
        end)

      assert add_output =~ "added/updated"

      remove_output = capture_io(fn -> PhoenixGenApi.rl_global(:remove, key) end)
      assert remove_output =~ "removed"
    end

    test "rl_config/0 prints the rate limit configuration" do
      output = capture_io(fn -> PhoenixGenApi.rl_config() end)
      assert output =~ "Rate Limit Configuration"
      assert output =~ "Global Limits:"
      assert output =~ "API Limits:"
    end

    test "cache_status/0 prints ConfigDb status" do
      output = capture_io(fn -> PhoenixGenApi.cache_status() end)
      assert output =~ "ConfigDb Cache Status"
    end

    test "pool_status/0 prints worker pool status" do
      output = capture_io(fn -> PhoenixGenApi.pool_status() end)
      assert output =~ "Async Pool:"
      assert output =~ "Stream Pool:"
    end

    test "health_print/0 prints a health check report" do
      output = capture_io(fn -> PhoenixGenApi.health_print() end)
      assert output =~ "PhoenixGenApi Health Check"
      assert output =~ "Status:"
    end

    test "stats_print/0 prints statistics" do
      output = capture_io(fn -> PhoenixGenApi.stats_print() end)
      assert output =~ "PhoenixGenApi Statistics"
      assert output =~ "Processes:"
    end

    test "debug_print/0 prints a debug report" do
      output = capture_io(fn -> PhoenixGenApi.debug_print() end)
      assert output =~ "Debug Report"
      assert output =~ "ETS Tables"
    end

    test "call_flow_print/3 prints an error when the config is unknown" do
      output = capture_io(fn -> PhoenixGenApi.call_flow_print("unknown_#{unique()}", "get") end)
      assert output =~ "Config not found"
    end

    test "call_flow_print/3 prints the flow for a known config" do
      request_type = "flow_print_#{unique()}"
      register_config(request_type)

      output = capture_io(fn -> PhoenixGenApi.call_flow_print("test_service", request_type) end)
      assert output =~ "Call Flow"
      assert output =~ "Execution Steps"
    end

    test "cluster_print/0 prints cluster topology" do
      output = capture_io(fn -> PhoenixGenApi.cluster_print() end)
      assert output =~ "Cluster View"
      assert output =~ "Node Selection Strategies"
    end

    test "flows_print/0 prints registered call flows" do
      output = capture_io(fn -> PhoenixGenApi.flows_print() end)
      assert output =~ "Registered Call Flows"
    end

    test "inspect_print/1 prints the request inspection" do
      request_type = "inspect_print_#{unique()}"
      register_config(request_type)

      output =
        capture_io(fn ->
          PhoenixGenApi.inspect_print(%{service: "test_service", request_type: request_type})
        end)

      assert output =~ "Request Inspection"
      assert output =~ "Execution Plan"
    end

    test "pushed_services_status/0 prints pushed services" do
      output = capture_io(fn -> PhoenixGenApi.pushed_services_status() end)
      assert output =~ "Pushed Services Status"
    end

    test "failed_configs_print/0 prints failed config entries" do
      ConfigFailed.clear()

      output = capture_io(fn -> PhoenixGenApi.failed_configs_print() end)
      assert output =~ "Failed FunConfig Entries"
      assert output =~ "(no failed entries)"

      entry =
        ConfigFailed.record(%FunConfig{service: "fp_svc", request_type: "fp_rt"}, "bad", :pull)

      filled =
        capture_io(fn -> PhoenixGenApi.failed_configs_print(source: :pull) end)

      assert filled =~ "fp_svc"
      assert filled =~ "#{entry.id}"

      :ok = PhoenixGenApi.clear_failed_configs()
    end

    test "failed_configs_summary/0 prints a summary" do
      ConfigFailed.clear()

      output = capture_io(fn -> PhoenixGenApi.failed_configs_summary() end)
      assert output =~ "Failed Configs Summary"

      ConfigFailed.record(%FunConfig{service: "fs_svc", request_type: "fs_rt"}, "bad", :push)

      filled = capture_io(fn -> PhoenixGenApi.failed_configs_summary() end)
      assert filled =~ "Total:"

      :ok = PhoenixGenApi.clear_failed_configs()
    end
  end

  describe "use PhoenixGenApi macro" do
    test "handle_in/3 executes a valid request and pushes the response" do
      channel = PhoenixGenApiTest.Channel
      request_type = "ch_success_#{unique()}"
      register_config(request_type)

      socket = %{ref: self(), assigns: %{user_id: "user_1"}}

      payload = %{
        "request_id" => "req_#{unique()}",
        "request_type" => request_type,
        "service" => "test_service",
        "user_id" => "user_1",
        "args" => %{}
      }

      assert {:reply, {:ok, ^request_type}, ^socket} =
               channel.handle_in("phoenix_gen_api", payload, socket)

      assert_received {:pushed, "phoenix_gen_api", %Response{success: true} = pushed}
      assert pushed.request_id == payload["request_id"]
    end

    test "handle_in/3 rejects unauthenticated requests when require_verified_user_id is true" do
      channel = PhoenixGenApiTest.Channel
      request_type = "ch_unauthed_#{unique()}"
      register_config(request_type)

      socket = %{ref: self(), assigns: %{}}

      payload = %{
        "request_id" => "req_#{unique()}",
        "request_type" => request_type,
        "service" => "test_service"
      }

      log =
        capture_log(fn ->
          assert {:reply, {:error, "Authentication required"}, ^socket} =
                   channel.handle_in("phoenix_gen_api", payload, socket)
        end)

      assert log =~ "rejected unauthenticated request"

      assert_received {:pushed, "phoenix_gen_api",
                       %Response{success: false, error: "Authentication required"}}
    end

    test "handle_in/3 returns an error response on decode failure" do
      channel = PhoenixGenApiTest.Channel

      socket = %{ref: self(), assigns: %{user_id: "user_1"}}
      payload = %{"request_id" => "req_#{unique()}"}

      assert {:reply, {:error, message}, ^socket} =
               channel.handle_in("phoenix_gen_api", payload, socket)

      assert message =~ "Missing required fields"

      assert_received {:pushed, "phoenix_gen_api", %Response{success: false, error: error}}
      assert error =~ "Invalid request:"
    end

    test "handle_in/3 returns an error response when permission is denied" do
      channel = PhoenixGenApiTest.Channel
      request_type = "ch_denied_#{unique()}"

      register_config(request_type,
        check_permission: {:arg, "user_id"},
        arg_types: %{"user_id" => :string},
        arg_orders: ["user_id"]
      )

      socket = %{ref: self(), assigns: %{user_id: "user_1"}}

      payload = %{
        "request_id" => "req_#{unique()}",
        "request_type" => request_type,
        "service" => "test_service",
        "user_id" => "other_user",
        "args" => %{"user_id" => "other_user"}
      }

      assert {:reply, {:ok, ^request_type}, ^socket} =
               channel.handle_in("phoenix_gen_api", payload, socket)

      assert_received {:pushed, "phoenix_gen_api",
                       %Response{success: false, error: "Permission denied"}}
    end

    test "override_user_id injects the verified socket user_id into the request" do
      channel = PhoenixGenApiTest.Channel
      request_type = "ch_override_#{unique()}"

      register_config(request_type,
        mfa: {__MODULE__, :echo_with_info, []},
        request_info: true,
        arg_types: %{"name" => :string},
        arg_orders: ["name"]
      )

      socket = %{ref: self(), assigns: %{user_id: "server_user"}}

      payload = %{
        "request_id" => "req_#{unique()}",
        "request_type" => request_type,
        "service" => "test_service",
        "user_id" => "client_user",
        "args" => %{"name" => "Bob"}
      }

      assert {:reply, {:ok, ^request_type}, ^socket} =
               channel.handle_in("phoenix_gen_api", payload, socket)

      assert_received {:pushed, "phoenix_gen_api", %Response{result: %{user_id: "server_user"}}}
    end

    test "override_user_id: false keeps the client-supplied user_id" do
      channel = PhoenixGenApiTest.ChannelNoOverride
      request_type = "ch_no_override_#{unique()}"

      register_config(request_type,
        mfa: {__MODULE__, :echo_with_info, []},
        request_info: true,
        arg_types: %{"name" => :string},
        arg_orders: ["name"]
      )

      socket = %{ref: self(), assigns: %{user_id: "server_user"}}

      payload = %{
        "request_id" => "req_#{unique()}",
        "request_type" => request_type,
        "service" => "test_service",
        "user_id" => "client_user",
        "args" => %{"name" => "Bob"}
      }

      assert {:reply, {:ok, ^request_type}, ^socket} =
               channel.handle_in("phoenix_gen_api", payload, socket)

      assert_received {:pushed, "phoenix_gen_api", %Response{result: %{user_id: "client_user"}}}
    end

    test "require_verified_user_id: false allows requests without a user_id" do
      channel = PhoenixGenApiTest.ChannelNoVerified
      request_type = "ch_no_verified_#{unique()}"
      register_config(request_type)

      socket = %{ref: self(), assigns: %{}}

      payload = %{
        "request_id" => "req_#{unique()}",
        "request_type" => request_type,
        "service" => "test_service",
        "args" => %{}
      }

      assert {:reply, {:ok, ^request_type}, ^socket} =
               channel.handle_in("phoenix_gen_api", payload, socket)

      assert_received {:pushed, "phoenix_gen_api", %Response{success: true}}
    end

    test "handle_in/3 pushes on the configured custom event" do
      channel = PhoenixGenApiTest.CustomEventChannel
      request_type = "ch_custom_event_#{unique()}"
      register_config(request_type)

      socket = %{ref: self(), assigns: %{user_id: "user_1"}}

      payload = %{
        "request_id" => "req_#{unique()}",
        "request_type" => request_type,
        "service" => "test_service",
        "user_id" => "user_1",
        "args" => %{}
      }

      assert {:reply, {:ok, ^request_type}, ^socket} =
               channel.handle_in("custom_event", payload, socket)

      assert_received {:pushed, "custom_event", %Response{success: true}}
    end

    test "handle_info/2 pushes {:push, result} on the channel event" do
      channel = PhoenixGenApiTest.Channel
      socket = %{ref: self()}

      assert {:noreply, ^socket} = channel.handle_info({:push, %{a: 1}}, socket)
      assert_received {:pushed, "phoenix_gen_api", %{a: 1}}
    end

    test "handle_info/2 pushes {:stream_response, result}" do
      channel = PhoenixGenApiTest.Channel
      socket = %{ref: self()}

      assert {:noreply, ^socket} = channel.handle_info({:stream_response, :chunk}, socket)
      assert_received {:pushed, "phoenix_gen_api", :chunk}
    end

    test "handle_info/2 pushes {:async_call, result}" do
      channel = PhoenixGenApiTest.Channel
      socket = %{ref: self()}

      assert {:noreply, ^socket} = channel.handle_info({:async_call, %{id: 1}}, socket)
      assert_received {:pushed, "phoenix_gen_api", %{id: 1}}
    end

    test "handle_info/2 pushes {:relay_message, result}" do
      channel = PhoenixGenApiTest.Channel
      socket = %{ref: self()}

      assert {:noreply, ^socket} = channel.handle_info({:relay_message, :msg}, socket)
      assert_received {:pushed, "phoenix_gen_api", :msg}
    end

    test "handle_info/2 handles {:stream_started, request_id, pid} without pushing" do
      channel = PhoenixGenApiTest.Channel
      socket = %{ref: self()}
      pid = self()

      assert {:noreply, ^socket} = channel.handle_info({:stream_started, "req_1", pid}, socket)
      assert Process.get({:phoenix_gen_api, :stream_call_pid, "req_1"}) == pid
      refute_received {:pushed, _, _}

      Process.delete({:phoenix_gen_api, :stream_call_pid, "req_1"})
    end
  end

  def dummy_stream_function do
    {:ok, :init}
  end

  def echo_fn do
    {:ok, %{echo: true}}
  end

  def echo_with_info(_name, info) do
    {:ok, %{user_id: info.user_id}}
  end
end
