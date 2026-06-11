defmodule PhoenixGenApi.DiagnosticsTest do
  use ExUnit.Case, async: true

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
      assert length(flow.steps) > 0

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
      assert length(flows) >= 1

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

  def test_fn, do: :ok
  def noop, do: :ok
end
