defmodule PhoenixGenApi.ConfigPusherTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Structs.PushConfig
  alias PhoenixGenApi.{ConfigPusher, ConfigReceiver}

  setup do
    # Clean ConfigDb
    :ets.delete_all_objects(PhoenixGenApi.ConfigDb)

    # Clean ConfigReceiver state
    ConfigReceiver.get_all_pushed_services()
    |> Enum.each(fn {service, _version} ->
      ConfigReceiver.delete_pushed_service(service)
    end)

    :ok
  end

  defp valid_fun_config(overrides \\ %{}) do
    defaults = %{
      request_type: "test_request",
      service: "test_service",
      nodes: [Node.self()],
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {String, :upcase, []},
      arg_types: %{},
      arg_orders: [],
      response_type: :sync,
      version: "1.0.0"
    }

    struct(PhoenixGenApi.Structs.FunConfig, Map.merge(defaults, Map.new(overrides)))
  end

  defp valid_push_config(overrides \\ %{}) do
    defaults = %{
      service: "test_service",
      nodes: [Node.self()],
      config_version: "1.0.0",
      fun_configs: [valid_fun_config()]
    }

    struct(PhoenixGenApi.Structs.PushConfig, Map.merge(defaults, Map.new(overrides)))
  end

  describe "push/2" do
    test "pushes config to local node and returns {:ok, :accepted}" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigPusher.push(Node.self(), config)
    end

    test "returns {:ok, :skipped, :version_matches} when pushing same version again" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigPusher.push(Node.self(), config)
      assert {:ok, :skipped, :version_matches} = ConfigPusher.push(Node.self(), config)
    end

    test "returns {:error, {:badrpc, _}} when pushing to unreachable node" do
      config = valid_push_config()
      assert {:error, {:badrpc, _}} = ConfigPusher.push(:nonexistent@host, config)
    end
  end

  describe "push/3" do
    test "pushes with force: true option" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigPusher.push(Node.self(), config)

      # Same version without force should be skipped
      assert {:ok, :skipped, :version_matches} =
               ConfigPusher.push(Node.self(), config, force: false)

      # Same version with force should be accepted
      assert {:ok, :accepted} = ConfigPusher.push(Node.self(), config, force: true)
    end

    test "pushes with custom timeout option" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigPusher.push(Node.self(), config, timeout: 10_000)
    end
  end

  describe "verify/3" do
    test "returns {:ok, :matched} after pushing and verifying same version" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigPusher.push(Node.self(), config)
      assert {:ok, :matched} = ConfigPusher.verify(Node.self(), "test_service", "1.0.0")
    end

    test "returns {:error, :not_found} for unknown service" do
      assert {:error, :not_found} = ConfigPusher.verify(Node.self(), "unknown_service", "1.0.0")
    end

    test "returns {:ok, :mismatch, stored_version} for different version" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigPusher.push(Node.self(), config)
      assert {:ok, :mismatch, "1.0.0"} = ConfigPusher.verify(Node.self(), "test_service", "2.0.0")
    end
  end

  describe "push_on_startup/3" do
    test "returns same result as push/3" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigPusher.push_on_startup(Node.self(), config, [])
    end

    test "works with valid config" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigPusher.push_on_startup(Node.self(), config, timeout: 10_000)

      # Pushing same version again should be skipped
      assert {:ok, :skipped, :version_matches} =
               ConfigPusher.push_on_startup(Node.self(), config, [])
    end
  end

  describe "from_service_config/4" do
    test "creates a PushConfig with required config_version" do
      fun_configs = [valid_fun_config()]

      push_config =
        ConfigPusher.from_service_config(
          "test_service",
          [Node.self()],
          fun_configs,
          config_version: "1.0.0"
        )

      assert %PushConfig{} = push_config
      assert push_config.service == "test_service"
      assert push_config.nodes == [Node.self()]
      assert push_config.config_version == "1.0.0"
      assert push_config.fun_configs == fun_configs
    end

    test "creates a PushConfig with all optional fields" do
      fun_configs = [valid_fun_config()]

      push_config =
        ConfigPusher.from_service_config(
          "test_service",
          [Node.self()],
          fun_configs,
          config_version: "1.0.0",
          module: MyApp.GenApi.Supporter,
          function: :get_config,
          args: [:arg1],
          version_module: MyApp.GenApi.Supporter,
          version_function: :get_config_version,
          version_args: [:varg1]
        )

      assert %PushConfig{} = push_config
      assert push_config.module == MyApp.GenApi.Supporter
      assert push_config.function == :get_config
      assert push_config.args == [:arg1]
      assert push_config.version_module == MyApp.GenApi.Supporter
      assert push_config.version_function == :get_config_version
      assert push_config.version_args == [:varg1]
    end

    test "raises ArgumentError when config_version is missing" do
      fun_configs = [valid_fun_config()]

      assert_raise ArgumentError, fn ->
        ConfigPusher.from_service_config(
          "test_service",
          [Node.self()],
          fun_configs,
          []
        )
      end
    end

    test "raises ArgumentError when config_version is empty string" do
      fun_configs = [valid_fun_config()]

      assert_raise ArgumentError, fn ->
        ConfigPusher.from_service_config(
          "test_service",
          [Node.self()],
          fun_configs,
          config_version: ""
        )
      end
    end
  end
end
