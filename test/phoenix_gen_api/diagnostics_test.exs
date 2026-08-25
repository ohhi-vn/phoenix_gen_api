defmodule PhoenixGenApi.DiagnosticsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixGenApi.Diagnostics

  describe "health_check/1" do
    test "returns a structured report with vm, node, and phoenix_gen_api checks" do
      report = Diagnostics.health_check()

      assert report.status in [:ok, :degraded, :error]
      assert report.node == Node.self()
      assert is_integer(report.checked_at_ms)
      assert Map.has_key?(report.checks, :vm)
      assert Map.has_key?(report.checks, :node)
      assert Map.has_key?(report.checks, :phoenix_gen_api)
    end

    test "supports max memory threshold" do
      report = Diagnostics.health_check(max_memory_bytes: 1)

      assert report.checks.vm.status == :degraded
      assert report.status in [:degraded, :error]
    end

    test "reports client mode when client_mode is true" do
      original = Application.get_env(:phoenix_gen_api, :client_mode, false)
      Application.put_env(:phoenix_gen_api, :client_mode, true)

      on_exit(fn ->
        Application.put_env(:phoenix_gen_api, :client_mode, original)
      end)

      report = Diagnostics.health_check()

      assert report.checks.phoenix_gen_api.mode == :client
      assert report.checks.phoenix_gen_api.status == :ok
    end
  end

  describe "statistics/1" do
    test "returns vm and phoenix_gen_api statistics" do
      stats = Diagnostics.statistics()

      assert stats.node == Node.self()
      assert is_integer(stats.collected_at_ms)
      assert Map.has_key?(stats.vm, :memory)
      assert Map.has_key?(stats.phoenix_gen_api, :client_mode)
      assert Map.has_key?(stats.phoenix_gen_api, :telemetry_events)
    end
  end

  describe "debug_report/1" do
    test "returns process and ets summaries" do
      report = Diagnostics.debug_report(process_limit: 3)

      assert report.node == Node.self()
      assert is_integer(report.collected_at_ms)
      assert is_list(report.processes)
      assert length(report.processes) <= 3
      assert Map.has_key?(report.ets_tables, inspect(PhoenixGenApi.ConfigDb))
      assert Map.has_key?(report.trace, :trace_control_word)
    end

    test "debug_report/0 uses default options" do
      report = Diagnostics.debug_report()

      assert is_list(report.processes)
      assert length(report.processes) <= 20
      assert is_map(report.ets_tables)
      assert is_map(report.trace)
    end

    test "debug_report/1 includes current stacktraces when requested" do
      report = Diagnostics.debug_report(process_limit: 5, include_current_stacktrace: true)

      assert is_list(report.processes)
      assert is_map(report.ets_tables)
    end
  end

  describe "call_flow/3" do
    test "returns error for unknown service" do
      flow = Diagnostics.call_flow("unknown_service", "unknown_action")

      assert flow.config == nil
      assert flow.error == :not_found
      assert is_list(flow.steps)
    end

    test "returns structured flow with steps for known config" do
      # Add a test config
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "test_action",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_fn, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false
      }

      PhoenixGenApi.ConfigDb.add(config)

      flow = Diagnostics.call_flow("test_service", "test_action")

      assert flow.config == config
      assert flow.local? == true
      assert flow.response_type == :sync
      assert flow.choose_node_mode == :random
      assert flow.timeout == 5000
      assert flow.mfa == {__MODULE__, :test_fn, []}
      assert is_list(flow.steps)
      assert flow.steps != []

      # Verify step structure
      Enum.each(flow.steps, fn step ->
        assert Map.has_key?(step, :phase)
        assert Map.has_key?(step, :desc)
      end)

      # Verify permission info
      assert flow.permission.strategy == :none

      # Verify hooks info
      assert flow.hooks.before_execute.configured == false
      assert flow.hooks.after_execute.configured == false

      # Verify retry info
      assert flow.retry.configured == false

      # Verify rate limit structure
      assert Map.has_key?(flow.rate_limit, :global)
      assert Map.has_key?(flow.rate_limit, :api)

      # Cleanup
      PhoenixGenApi.ConfigDb.delete("test_service", "test_action")
    end

    test "resolves version when not specified" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "versioned_action",
        service: "versioned_service",
        nodes: [:nonexistent@host],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_fn, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        version: "1.0.0"
      }

      PhoenixGenApi.ConfigDb.add(config)

      flow = Diagnostics.call_flow("versioned_service", "versioned_action")

      assert flow.config == config
      assert flow.version == "1.0.0"
      assert flow.nodes == [:nonexistent@host]

      # Cleanup
      PhoenixGenApi.ConfigDb.delete("versioned_service", "versioned_action", "1.0.0")
    end

    test "returns error flow for a disabled config" do
      {service, request_type, _config} =
        insert_config!(disabled: true, response_type: :sync)

      flow = Diagnostics.call_flow(service, request_type)

      assert flow.config == nil
      assert flow.error == :disabled
      assert is_list(flow.steps)
    end

    test "covers every permission strategy" do
      cases = [
        {true, :authenticated},
        {{:arg, "user_id"}, :arg_based},
        {{:role, [:admin]}, :role_based},
        {{ScratchPermissionMod, :check}, :custom_mfa},
        {"unexpected", :unknown}
      ]

      Enum.each(cases, fn {check_permission, expected} ->
        {service, request_type, _config} =
          insert_config!(check_permission: check_permission, nodes: :local)

        flow = Diagnostics.call_flow(service, request_type)

        assert flow.permission.strategy == expected,
               "expected #{inspect(expected)} for #{inspect(check_permission)}"
      end)
    end

    test "covers every hook format" do
      {service1, rt1, _} = insert_config!(before_execute: {ScratchHookMod, :before_fun})
      flow1 = Diagnostics.call_flow(service1, rt1)
      assert flow1.hooks.before_execute.configured == true
      assert flow1.hooks.before_execute.args == 2
      assert Enum.any?(flow1.steps, &(&1.phase == :hooks_before))

      {service2, rt2, _} =
        insert_config!(
          before_execute: {ScratchHookMod, :before_fun, [:a, :b]},
          after_execute: {ScratchHookMod, :after_fun, [:c]}
        )

      flow2 = Diagnostics.call_flow(service2, rt2)
      assert flow2.hooks.before_execute.args == 4
      assert flow2.hooks.after_execute.configured == true
      assert flow2.hooks.after_execute.args == 3
      assert Enum.any?(flow2.steps, &(&1.phase == :hooks_after))

      {service3, rt3, _} =
        insert_config!(before_execute: "weird", after_execute: 42)

      flow3 = Diagnostics.call_flow(service3, rt3)
      assert flow3.hooks.before_execute.configured == true
      assert flow3.hooks.before_execute.raw == "weird"
      assert flow3.hooks.after_execute.raw == 42
    end

    test "covers every retry format" do
      {service1, rt1, _} = insert_config!(retry: 3)
      flow1 = Diagnostics.call_flow(service1, rt1)
      assert flow1.retry.configured == true
      assert flow1.retry.mode == :all_nodes
      assert Enum.any?(flow1.steps, &(&1.phase == :retry))

      {service2, rt2, _} = insert_config!(retry: {:same_node, 2})
      flow2 = Diagnostics.call_flow(service2, rt2)
      assert flow2.retry.mode == :same_node
      assert flow2.retry.attempts == 2

      {service3, rt3, _} = insert_config!(retry: {:all_nodes, 4})
      flow3 = Diagnostics.call_flow(service3, rt3)
      assert flow3.retry.mode == :all_nodes
      assert flow3.retry.attempts == 4
    end

    test "covers every response type" do
      {service1, rt1, _} = insert_config!(response_type: :async)
      flow1 = Diagnostics.call_flow(service1, rt1)
      assert flow1.response_type == :async
      assert Enum.any?(flow1.steps, &(&1.phase == :response))
      refute Enum.any?(flow1.steps, &(&1.desc == "ArgumentHandler.convert_args!/2"))

      {service2, rt2, _} = insert_config!(response_type: :none)
      flow2 = Diagnostics.call_flow(service2, rt2)
      assert flow2.response_type == :none
      refute Enum.any?(flow2.steps, &(&1.desc == "ArgumentHandler.convert_args!/2"))

      {service3, rt3, _} = insert_config!(response_type: :stream)
      flow3 = Diagnostics.call_flow(service3, rt3)
      assert Enum.any?(flow3.steps, &(&1.desc =~ "Stream chunks"))

      {service4, rt4, _} = insert_config!(response_type: :custom)
      flow4 = Diagnostics.call_flow(service4, rt4)
      assert Enum.any?(flow4.steps, &(&1.desc == "Response type: :custom"))
    end

    test "resolves nodes from an MFA tuple" do
      {service1, rt1, _} = insert_config!(nodes: {__MODULE__, :diag_nodes_fn, []})
      flow1 = Diagnostics.call_flow(service1, rt1)
      assert flow1.nodes == [:diag_node_a@host, :diag_node_b@host]
      assert flow1.local? == false

      {service2, rt2, _} = insert_config!(nodes: {__MODULE__, :diag_nodes_nonlist, []})
      flow2 = Diagnostics.call_flow(service2, rt2)
      assert flow2.nodes == []

      {service3, rt3, _} = insert_config!(nodes: {ScratchNonExistentNodeMod, :foo, []})
      flow3 = Diagnostics.call_flow(service3, rt3)
      assert flow3.nodes == []

      {service4, rt4, _} = insert_config!(nodes: "not_a_node_atom")
      flow4 = Diagnostics.call_flow(service4, rt4)
      assert flow4.nodes == ["not_a_node_atom"]
      assert flow4.reachable_nodes == []
      assert flow4.unreachable_nodes == ["not_a_node_atom"]
    end

    test "reports configured rate limit scopes" do
      original_limits =
        if Process.whereis(:rate_limiter_supervisor) do
          PhoenixGenApi.RateLimiter.get_configured_limits()
        else
          %{global: [], api: []}
        end

      service = "diag_rl_svc_#{System.unique_integer([:positive])}"
      request_type = "diag_rl_rt"

      :ok =
        PhoenixGenApi.RateLimiter.update_config(%{
          global_limits: [%{key: :user_id, max_requests: 100, window_ms: 60_000}],
          api_limits: [
            %{
              key: :user_id,
              max_requests: 5,
              window_ms: 10_000,
              service: service,
              request_type: request_type
            },
            %{
              key: :user_id,
              max_requests: 7,
              window_ms: 20_000,
              service: "some_other_service",
              request_type: request_type
            }
          ]
        })

      on_exit(fn ->
        PhoenixGenApi.RateLimiter.update_config(%{
          global_limits: original_limits.global,
          api_limits: original_limits.api
        })
      end)

      insert_config!(service: service, request_type: request_type, nodes: :local)

      flow = Diagnostics.call_flow(service, request_type)

      assert length(flow.rate_limit.global) == 1
      assert flow.rate_limit.global |> hd() |> Map.get(:scope) == :global
      assert flow.rate_limit.global |> hd() |> Map.get(:max_requests) == 100
      assert flow.rate_limit.global |> hd() |> Map.get(:window_ms) == 60_000

      assert length(flow.rate_limit.api) == 1
      assert flow.rate_limit.api |> hd() |> Map.get(:scope) == :api
      assert flow.rate_limit.api |> hd() |> Map.get(:max_requests) == 5
    end
  end

  describe "inspect_request/1" do
    test "returns execution plan for a request map" do
      request = %{
        service: "unknown_service",
        request_type: "unknown_action",
        user_id: "user_123",
        request_id: "req_456"
      }

      plan = Diagnostics.inspect_request(request)

      assert plan.request.service == "unknown_service"
      assert plan.request.request_type == "unknown_action"
      assert plan.request.user_id == "user_123"
      assert plan.request.request_id == "req_456"
      assert plan.config == nil
    end

    test "handles string and atom keys" do
      request = %{
        "service" => "unknown_service",
        "request_type" => "unknown_action"
      }

      plan = Diagnostics.inspect_request(request)

      assert plan.request.service == "unknown_service"
      assert plan.request.request_type == "unknown_action"
    end
  end

  describe "cluster_view/0" do
    test "returns cluster topology" do
      view = Diagnostics.cluster_view()

      assert view.self == Node.self()
      assert is_list(view.connected)
      assert is_integer(view.connected_count)
      assert Map.has_key?(view.registered_processes, Node.self())
      assert is_map(view.phoenix_gen_api_services)
      assert Map.has_key?(view.node_selection, :strategies)
    end
  end

  describe "list_call_flows/1" do
    test "returns empty list when no configs" do
      PhoenixGenApi.ConfigDb.clear()

      flows = Diagnostics.list_call_flows()
      assert flows == []
    end

    test "returns flows for registered configs" do
      PhoenixGenApi.ConfigDb.clear()

      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "list_test_action",
        service: "list_test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_fn, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false
      }

      PhoenixGenApi.ConfigDb.add(config)

      flows = Diagnostics.list_call_flows()
      assert flows != []

      flow = Enum.find(flows, &(&1.service == "list_test_service"))
      assert flow != nil
      assert flow.request_type == "list_test_action"
      assert flow.local? == true
      assert flow.disabled == false
      assert is_list(flow.steps)

      # Cleanup
      PhoenixGenApi.ConfigDb.clear()
    end

    test "excludes disabled configs by default" do
      PhoenixGenApi.ConfigDb.clear()

      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "disabled_action",
        service: "disabled_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_fn, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false
      }

      PhoenixGenApi.ConfigDb.add(config)
      PhoenixGenApi.ConfigDb.disable("disabled_service", "disabled_action")

      flows = Diagnostics.list_call_flows()
      refute Enum.any?(flows, &(&1.service == "disabled_service"))

      flows = Diagnostics.list_call_flows(include_disabled: true)
      assert Enum.any?(flows, &(&1.service == "disabled_service"))

      # Cleanup
      PhoenixGenApi.ConfigDb.clear()
    end
  end

  describe "trace helpers" do
    test "trace_status returns trace control word" do
      assert %{node: node, trace_control_word: _} = Diagnostics.trace_status()
      assert node == Node.self()
    end

    test "trace operations are denied without admin action" do
      assert {:error, :admin_action_denied} = Diagnostics.trace_processes(self())
      assert {:error, :admin_action_denied} = Diagnostics.trace_functions({__MODULE__, :noop})
      assert {:error, :admin_action_denied} = Diagnostics.stop_trace(self())

      assert {:error, :admin_action_denied} =
               Diagnostics.stop_trace_functions({__MODULE__, :noop})
    end
  end

  describe "trace_processes/2" do
    setup do
      enable_admin_actions()
      :ok
    end

    test "enables tracing for the :all target" do
      me = self()

      assert {:ok, result} = Diagnostics.trace_processes(:all, flags: [])

      assert result.targets == [:all]
      assert result.flags == []
      assert result.tracer == me
      assert is_map(result.results)
    end

    test "enables tracing for a pid target" do
      me = self()

      assert {:ok, result} = Diagnostics.trace_processes([me], flags: [])

      assert result.targets == [me]
      assert result.flags == []
      assert is_map(result.results)
      assert Map.get(result.results, inspect(me)) == 1
    end

    test "enables tracing for a port target" do
      port = Port.open({:spawn, "sleep 60"}, [:binary])

      assert {:ok, result} = Diagnostics.trace_processes([port], flags: [])

      assert result.targets == [port]
      assert is_map(result.results)

      Port.close(port)
    end

    test "supports custom trace flags" do
      target =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> send(target, :stop) end)

      assert {:ok, result} =
               Diagnostics.trace_processes([target], flags: [:call, :procs, :ports])

      assert result.flags == [:call, :procs, :ports]
    end

    test "rejects invalid trace flags" do
      assert {:error, :invalid_trace_flag} =
               Diagnostics.trace_processes(self(), flags: [:call, :bogus_flag])
    end

    test "rejects an invalid tracer" do
      assert {:error, :invalid_tracer} =
               Diagnostics.trace_processes(self(), tracer: :not_a_pid)
    end

    test "rejects a non-traceable target type" do
      assert {:error, :invalid_trace_target} =
               Diagnostics.trace_processes("a_string_target", flags: [])
    end

    test "warns and rejects a process-target atom that is not a loaded module" do
      log =
        capture_log(fn ->
          assert {:error, {:invalid_trace_target, invalid}} =
                   Diagnostics.trace_processes(:processes, flags: [])

          assert invalid == [:processes]
        end)

      assert log =~ "Trace target module not loaded"
    end
  end

  describe "trace_functions/2" do
    setup do
      enable_admin_actions()
      :ok
    end

    test "traces a {module, function} mfa" do
      me = self()

      assert {:ok, result} =
               Diagnostics.trace_functions({__MODULE__, :noop},
                 flags: [],
                 match_spec: [],
                 tracer: me
               )

      assert result.mfas == [{__MODULE__, :noop, :_}]
      assert result.flags == []
      assert result.match_spec == []
      assert result.tracer == me
      assert is_map(result.pattern_results)
      assert is_map(result.process_trace.results)
    end

    test "traces a list of mfas with arities" do
      assert {:ok, result} =
               Diagnostics.trace_functions([{__MODULE__, :noop}, {__MODULE__, :noop, 0}],
                 flags: [],
                 match_spec: true
               )

      assert Enum.sort(result.mfas) == [{__MODULE__, :noop, 0}, {__MODULE__, :noop, :_}]
    end

    test "traces the :all mfa sentinel" do
      log =
        capture_log(fn ->
          assert {:error, {:invalid_mfa, invalid}} = Diagnostics.trace_functions(:all)

          assert invalid == [{:_, :_, :_}]
        end)

      assert log =~ "Trace MFA module not loaded"
    end

    test "traces a list containing the :all mfa sentinel" do
      log =
        capture_log(fn ->
          assert {:error, {:invalid_mfa, invalid}} = Diagnostics.trace_functions([:all])

          assert invalid == [{:_, :_, :_}]
        end)

      assert log =~ "Trace MFA module not loaded"
    end

    test "warns and rejects an mfa whose module is not loaded" do
      log =
        capture_log(fn ->
          assert {:error, {:invalid_mfa, invalid}} =
                   Diagnostics.trace_functions({ScratchNonExistentMod, :foo})

          assert invalid == [{ScratchNonExistentMod, :foo, :_}]
        end)

      assert log =~ "Trace MFA module not loaded"
    end

    test "rejects an invalid mfa value" do
      assert {:error, :invalid_mfa} = Diagnostics.trace_functions("garbage")
      assert {:error, :invalid_mfa} = Diagnostics.trace_functions({__MODULE__, :noop, -1})
    end

    test "rejects an invalid match spec" do
      assert {:error, :invalid_match_spec} =
               Diagnostics.trace_functions({__MODULE__, :noop}, match_spec: :not_a_spec)
    end
  end

  describe "stop_trace/2 and stop_trace_functions/1" do
    setup do
      enable_admin_actions()
      :ok
    end

    test "stop_trace disables tracing for a pid" do
      me = self()

      assert {:ok, result} = Diagnostics.stop_trace([me], flags: [])

      assert result.targets == [me]
      assert result.flags == []
      assert is_map(result.results)
    end

    test "stop_trace handles the :all target" do
      assert {:ok, result} = Diagnostics.stop_trace(:all, flags: [])

      assert result.targets == [:all]
      assert is_map(result.results)
    end

    test "stop_trace_functions clears patterns for an mfa" do
      assert {:ok, result} = Diagnostics.stop_trace_functions({__MODULE__, :noop})

      assert result.mfas == [{__MODULE__, :noop, :_}]
      assert is_map(result.results)
    end

    test "stop_trace_functions handles the :all sentinel" do
      assert {:ok, result} = Diagnostics.stop_trace_functions(:all)

      assert result.mfas == [{:_, :_, :_}]
      assert is_map(result.results)
    end

    test "stop_trace_functions/0 uses the :all default" do
      assert {:ok, result} = Diagnostics.stop_trace_functions()

      assert result.mfas == [{:_, :_, :_}]
      assert is_map(result.results)
    end
  end

  describe "health and statistics checks with stopped application" do
    test "report not-started components and rate limiter edge states" do
      :ok = Application.stop(:phoenix_gen_api)

      report = Diagnostics.health_check()
      checks = report.checks.phoenix_gen_api
      assert checks.checks.config_db.reason == :not_registered
      assert checks.checks.rate_limiter_instances.reason == :not_registered
      assert checks.checks.supervision_tree.reason == :supervisor_not_found

      stats = Diagnostics.statistics()
      assert stats.phoenix_gen_api.config_db.status == :error
      assert stats.phoenix_gen_api.config_puller.status == :error
      assert stats.phoenix_gen_api.config_receiver.status == :error
      assert stats.phoenix_gen_api.rate_limiter.status == :error
      assert stats.phoenix_gen_api.worker_pool.async_pool.status == :error
      assert stats.phoenix_gen_api.worker_pool.stream_pool.status == :error
      assert stats.phoenix_gen_api.relay.status == :error

      dreport = Diagnostics.debug_report()
      assert Enum.all?(Map.values(dreport.ets_tables), &(&1.exists == false))

      # A live rate limiter supervisor with no instances => :ok / no_limits_configured
      {:ok, sup} =
        Supervisor.start_link([], strategy: :one_for_one, name: :rate_limiter_supervisor)

      report = Diagnostics.health_check()
      rl = report.checks.phoenix_gen_api.checks.rate_limiter_instances
      assert rl.status == :ok
      assert rl.reason == :no_limits_configured

      # Add a single alive instance but leave others unregistered => :degraded
      inst_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Process.register(inst_pid, :rate_limiter_instance_0)

      report = Diagnostics.health_check()
      rl = report.checks.phoenix_gen_api.checks.rate_limiter_instances
      assert rl.status == :degraded
      assert rl.reason == :partial_failure

      send(inst_pid, :stop)
      Supervisor.stop(sup)

      {:ok, _} = Application.ensure_all_started(:phoenix_gen_api)
      assert Process.whereis(PhoenixGenApi.ConfigDb) != nil
      assert Process.whereis(:rate_limiter_supervisor) != nil
    end
  end

  defp enable_admin_actions do
    original = Application.get_env(:phoenix_gen_api, :admin_actions, [])

    Application.put_env(:phoenix_gen_api, :admin_actions, [
      :enable_tracing,
      :disable_tracing
    ])

    on_exit(fn ->
      Application.put_env(:phoenix_gen_api, :admin_actions, original)
    end)

    :ok
  end

  defp insert_config!(overrides) do
    overrides = Map.new(overrides)

    service = Map.get(overrides, :service, "diag_svc_#{System.unique_integer([:positive])}")

    request_type =
      Map.get(overrides, :request_type, "diag_rt_#{System.unique_integer([:positive])}")

    base = %PhoenixGenApi.Structs.FunConfig{
      request_type: request_type,
      service: service,
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :test_fn, []},
      arg_types: nil,
      arg_orders: [],
      response_type: :sync,
      check_permission: false
    }

    config = Map.merge(base, Map.drop(overrides, [:service, :request_type]))

    :ets.insert(PhoenixGenApi.ConfigDb, {{service, request_type, nil}, config})

    on_exit(fn ->
      :ets.delete(PhoenixGenApi.ConfigDb, {service, request_type, nil})
    end)

    {service, request_type, config}
  end

  def test_fn, do: :ok
  def noop, do: :ok

  def diag_nodes_fn, do: [:diag_node_a@host, :diag_node_b@host]
  def diag_nodes_nonlist, do: :not_a_list
end
