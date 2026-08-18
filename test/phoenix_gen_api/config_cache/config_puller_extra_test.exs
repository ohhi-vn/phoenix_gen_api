defmodule PhoenixGenApi.ConfigPullerExtraTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.ConfigPuller
  alias PhoenixGenApi.Structs.{ServiceConfig, FunConfig}

  defmodule TestPullService do
    def nodes_ok, do: [Node.self()]
    def bad_nodes, do: :not_a_list
    def raise_fun, do: raise("boom")
    def throw_fun, do: throw(:boom)

    def get_version, do: "v1"

    def get_config do
      {:ok,
       [
         %FunConfig{
           request_type: "coverage_pull_ok",
           service: "coverage_pull_service",
           nodes: [Node.self()],
           choose_node_mode: :random,
           timeout: 5000,
           mfa: {String, :upcase, []},
           arg_types: %{"text" => :string},
           arg_orders: ["text"],
           response_type: :sync,
           check_permission: false,
           request_info: false
         }
       ]}
    end

    def get_config_not_list, do: {:ok, :not_a_list}

    def get_config_bad_item do
      {:ok, [%{not: "a config"}]}
    end

    def get_config_invalid do
      {:ok,
       [
         %FunConfig{
           request_type: "coverage_pull_invalid",
           service: "coverage_pull_invalid_service",
           nodes: [Node.self()],
           choose_node_mode: :random,
           timeout: 5000,
           mfa: {String, :upcase, []},
           arg_types: nil,
           arg_orders: [],
           response_type: :bogus,
           check_permission: false,
           request_info: false
         }
       ]}
    end

    def get_config_unsafe_mfa do
      {:ok,
       [
         %FunConfig{
           request_type: "coverage_pull_unsafe",
           service: "coverage_pull_unsafe_service",
           nodes: [Node.self()],
           choose_node_mode: :random,
           timeout: 5000,
           mfa: {NonExistentPullModule, :foo, []},
           arg_types: nil,
           arg_orders: [],
           response_type: :sync,
           check_permission: false,
           request_info: false
         }
       ]}
    end

    def get_config_bad_mfa_format do
      {:ok,
       [
         %FunConfig{
           request_type: "coverage_pull_bad_mfa",
           service: "coverage_pull_bad_mfa_service",
           nodes: [Node.self()],
           choose_node_mode: :random,
           timeout: 5000,
           mfa: :oops,
           arg_types: nil,
           arg_orders: [],
           response_type: :sync,
           check_permission: false,
           request_info: false
         }
       ]}
    end

    def get_config_denied_mfa do
      {:ok,
       [
         %FunConfig{
           request_type: "coverage_pull_denied",
           service: "coverage_pull_denied_service",
           nodes: [Node.self()],
           choose_node_mode: :random,
           timeout: 5000,
           mfa: {:os, :cmd, []},
           arg_types: nil,
           arg_orders: [],
           response_type: :sync,
           check_permission: false,
           request_info: false
         }
       ]}
    end
  end

  setup do
    leftover =
      ConfigPuller.get_all_versions()
      |> Map.keys()
      |> Enum.map(fn key -> %ServiceConfig{service: key} end)

    if leftover != [], do: ConfigPuller.delete(leftover)

    :ok
  end

  defp service(service, module, function, nodes, opts \\ []) do
    struct(
      ServiceConfig,
      [
        service: service,
        nodes: nodes,
        module: module,
        function: function,
        args: []
      ] ++ opts
    )
  end

  defp wait_for(fun, attempts \\ 300) do
    if fun.() do
      :ok
    else
      if attempts == 0 do
        flunk("condition not met in time")
      else
        Process.sleep(50)
        wait_for(fun, attempts - 1)
      end
    end
  end

  describe "start_link/0 default options" do
    test "calls start_link with default opts" do
      assert {:error, {:already_started, _pid}} = ConfigPuller.start_link()
    end
  end

  describe "initial data load from application config" do
    test "loads services from :gen_api env on restart" do
      original = Application.get_env(:phoenix_gen_api, :gen_api)

      on_exit(fn ->
        if original do
          Application.put_env(:phoenix_gen_api, :gen_api, original)
        else
          Application.delete_env(:phoenix_gen_api, :gen_api)
        end

        ensure_puller_running()
      end)

      Application.put_env(:phoenix_gen_api, :gen_api,
        service_configs: [
          %{
            "service" => "env_loaded_service",
            "nodes" => [Node.self()],
            "module" => "TestModule",
            "function" => "get_config",
            "args" => []
          }
        ]
      )

      restart_puller()

      services = ConfigPuller.get_services()
      assert Map.has_key?(services, "env_loaded_service")
    end
  end

  describe "handle_info/2" do
    test "handles :cleanup_sticky" do
      send(Process.whereis(ConfigPuller), :cleanup_sticky)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(ConfigPuller))
    end

    test "catch-all ignores unknown messages" do
      send(Process.whereis(ConfigPuller), {:random, :message})
      Process.sleep(50)
      assert Process.alive?(Process.whereis(ConfigPuller))
    end
  end

  describe "pull failure and recovery" do
    test "increments failure count then recovers on a successful pull" do
      service_name = "coverage_fail_recover_service"

      # Isolate this test: drop any services left by other tests so the pull
      # only processes our fast-failing service.
      leftover =
        ConfigPuller.get_all_versions()
        |> Map.keys()
        |> Enum.map(fn key -> %PhoenixGenApi.Structs.ServiceConfig{service: key} end)

      ConfigPuller.delete(leftover)

      fail_service = service(service_name, TestPullService, :get_config, [:nonode@unreachable])
      ok_service = service(service_name, TestPullService, :get_config, [Node.self()])

      ConfigPuller.add([fail_service])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status().failure_count >= 1 end)

      ConfigPuller.delete([fail_service])
      ConfigPuller.add([ok_service])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status().failure_count == 0 end)

      assert ConfigPuller.get_api_list(service_name) == ["coverage_pull_ok"]
    end
  end

  describe "node resolution via MFA" do
    test "resolves nodes from an MFA returning a list" do
      service_name = "coverage_mfa_nodes_service"
      svc = service(service_name, TestPullService, :get_config, {TestPullService, :nodes_ok, []})
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.get_api_list(service_name) == ["coverage_pull_ok"] end)
    end

    test "logs invalid node list from MFA" do
      service_name = "coverage_bad_nodes_service"
      svc = service(service_name, TestPullService, :get_config, {TestPullService, :bad_nodes, []})
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end

    test "rescues errors raised by the MFA" do
      service_name = "coverage_raise_nodes_service"
      svc = service(service_name, TestPullService, :get_config, {TestPullService, :raise_fun, []})
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end
  end

  describe "invalid nodes configuration" do
    test "logs and returns no nodes for invalid nodes value" do
      service_name = "coverage_invalid_nodes_service"
      svc = service(service_name, TestPullService, :get_config, :not_a_list)
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end
  end

  describe "version-based skip" do
    test "skips the pull when the version matches the stored version" do
      service_name = "coverage_skip_service"

      svc =
        service(service_name, TestPullService, :get_config, [Node.self()],
          version_module: TestPullService,
          version_function: :get_version,
          version_args: []
        )

      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.get_api_list(service_name) == ["coverage_pull_ok"] end)

      version = ConfigPuller.get_service_version(service_name)
      assert version == "v1"

      ConfigPuller.pull()
      Process.sleep(100)

      assert ConfigPuller.get_service_version(service_name) == "v1"
    end
  end

  describe "version check fallback" do
    test "falls back to the next node when the first version RPC fails" do
      service_name = "coverage_version_fallback_service"

      svc =
        service(service_name, TestPullService, :get_config, [:nonode@unreachable, Node.self()],
          version_module: TestPullService,
          version_function: :get_version,
          version_args: []
        )

      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.get_api_list(service_name) == ["coverage_pull_ok"] end)
    end

    test "falls back to full pull when all version RPCs fail" do
      service_name = "coverage_version_all_fail_service"

      svc =
        service(service_name, TestPullService, :get_config, [:nonode@unreachable],
          version_module: TestPullService,
          version_function: :get_version,
          version_args: []
        )

      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end
  end

  describe "rpc fallback" do
    test "falls back to the next node when the config RPC fails" do
      service_name = "coverage_rpc_fallback_service"
      svc = service(service_name, TestPullService, :get_config, [:nonode@unreachable, Node.self()])
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.get_api_list(service_name) == ["coverage_pull_ok"] end)
    end

    test "handles unexpected RPC result and falls back" do
      service_name = "coverage_rpc_unexpected_service"

      svc =
        service(service_name, TestPullService, :get_config_not_list, [Node.self(), :nonode@unreachable])

      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end
  end

  describe "fun_list processing" do
    test "inserts valid configs into ConfigDb" do
      service_name = "coverage_insert_service"
      svc = service(service_name, TestPullService, :get_config, [Node.self()])
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.get_api_list(service_name) == ["coverage_pull_ok"] end)

      assert {:ok, _config} =
               PhoenixGenApi.ConfigDb.get(service_name, "coverage_pull_ok", nil)
    end

    test "records invalid configs and skips them" do
      service_name = "coverage_invalid_config_service"
      svc = service(service_name, TestPullService, :get_config_invalid, [Node.self()])
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end

    test "rejects configs whose MFA module is not loaded" do
      service_name = "coverage_unsafe_mfa_service"
      svc = service(service_name, TestPullService, :get_config_unsafe_mfa, [Node.self()])
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end

    test "rejects configs with an invalid MFA format" do
      service_name = "coverage_bad_mfa_service"
      svc = service(service_name, TestPullService, :get_config_bad_mfa_format, [Node.self()])
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end

    test "logs batch_add all_invalid when ConfigDb rejects all entries" do
      service_name = "coverage_denied_mfa_service"
      svc = service(service_name, TestPullService, :get_config_denied_mfa, [Node.self()])
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end

    test "skips non-FunConfig items in the fun_list" do
      service_name = "coverage_bad_item_service"
      svc = service(service_name, TestPullService, :get_config_bad_item, [Node.self()])
      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end
  end

  describe "unexpected errors during pull" do
    test "catches throws from node resolution MFA" do
      service_name = "coverage_throw_service"

      svc =
        service(service_name, TestPullService, :get_config, {TestPullService, :throw_fun, []})

      ConfigPuller.add([svc])
      ConfigPuller.pull()

      wait_for(fn -> ConfigPuller.status() != nil end)
    end
  end

  defp restart_puller do
    :ok = Supervisor.terminate_child(PhoenixGenApi.Supervisor, ConfigPuller)
    {:ok, _pid} = Supervisor.restart_child(PhoenixGenApi.Supervisor, ConfigPuller)
    wait_for(fn -> Process.whereis(ConfigPuller) != nil end)
  end

  defp ensure_puller_running do
    if Process.whereis(ConfigPuller) == nil do
      {:ok, _pid} = Supervisor.restart_child(PhoenixGenApi.Supervisor, ConfigPuller)
      wait_for(fn -> Process.whereis(ConfigPuller) != nil end)
    end
  end
end