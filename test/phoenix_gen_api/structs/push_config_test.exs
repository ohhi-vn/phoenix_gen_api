defmodule PhoenixGenApi.PushConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.{PushConfig, FunConfig, ServiceConfig}

  defp valid_push_config(overrides \\ %{}) do
    fun_config = %FunConfig{
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

    defaults = %{
      service: "test_service",
      nodes: [Node.self()],
      config_version: "1.0.0",
      fun_configs: [fun_config]
    }

    struct(PushConfig, Map.merge(defaults, Map.new(overrides)))
  end

  describe "from_map/1" do
    test "decodes a map with atom keys into a PushConfig" do
      data = %{
        service: "test_service",
        nodes: [Node.self()],
        config_version: "1.0.0",
        fun_configs: []
      }

      config = PushConfig.from_map(data)

      assert %PushConfig{} = config
      assert config.service == "test_service"
      assert config.nodes == [Node.self()]
      assert config.config_version == "1.0.0"
    end

    test "decodes a map with string keys into a PushConfig" do
      data = %{
        "service" => "test_service",
        "nodes" => [Node.self()],
        "config_version" => "1.0.0",
        "fun_configs" => []
      }

      config = PushConfig.from_map(data)

      assert %PushConfig{} = config
      assert config.service == "test_service"
      assert config.nodes == [Node.self()]
      assert config.config_version == "1.0.0"
    end
  end

  describe "valid?/1" do
    test "returns true for a valid PushConfig" do
      config = valid_push_config()
      assert PushConfig.valid?(config) == true
    end

    test "returns false when service is nil" do
      config = valid_push_config(service: nil)
      assert PushConfig.valid?(config) == false
    end

    test "returns false when nodes is empty" do
      config = valid_push_config(nodes: [])
      assert PushConfig.valid?(config) == false
    end

    test "returns false when nodes is not a list" do
      config = valid_push_config(nodes: "not_a_list")
      assert PushConfig.valid?(config) == false
    end

    test "returns false when config_version is empty string" do
      config = valid_push_config(config_version: "")
      assert PushConfig.valid?(config) == false
    end

    test "returns false when config_version is nil" do
      config = valid_push_config(config_version: nil)
      assert PushConfig.valid?(config) == false
    end

    test "returns false when fun_configs is empty list" do
      config = valid_push_config(fun_configs: [])
      assert PushConfig.valid?(config) == false
    end

    test "returns false when fun_configs is not a list" do
      config = valid_push_config(fun_configs: "not_a_list")
      assert PushConfig.valid?(config) == false
    end

    test "returns false when fun_configs contains non-FunConfig items" do
      config = valid_push_config(fun_configs: [%{request_type: "test"}])
      assert PushConfig.valid?(config) == false
    end

    test "returns false when fun_configs have different service name" do
      fun_config = %FunConfig{
        request_type: "test_request",
        service: "different_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {String, :upcase, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        version: "1.0.0"
      }

      config = valid_push_config(fun_configs: [fun_config])
      assert PushConfig.valid?(config) == false
    end

    test "returns true when fun_configs service is atom and push service is string (same value)" do
      fun_config = %FunConfig{
        request_type: "test_request",
        service: :test_service,
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {String, :upcase, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        version: "1.0.0"
      }

      config = valid_push_config(fun_configs: [fun_config])
      assert PushConfig.valid?(config) == true
    end
  end

  describe "validate_with_details/1" do
    test "returns {:ok, config} for valid config" do
      config = valid_push_config()
      assert {:ok, ^config} = PushConfig.validate_with_details(config)
    end

    test "returns {:error, messages} with specific error messages for invalid config" do
      config = valid_push_config(service: nil, nodes: [], config_version: "")
      assert {:error, messages} = PushConfig.validate_with_details(config)
      assert is_list(messages)
      assert "service must not be nil" in messages
      assert "nodes must be a non-empty list of atoms or strings" in messages
      assert "config_version must be a non-empty string" in messages
    end
  end

  describe "to_service_config/1" do
    test "returns ServiceConfig when module and function are present" do
      config =
        valid_push_config(
          module: SomeModule,
          function: :get_config,
          args: [],
          version_module: SomeModule,
          version_function: :get_version,
          version_args: []
        )

      result = PushConfig.to_service_config(config)

      assert %ServiceConfig{} = result
    end

    test "returns nil when module is nil" do
      config = valid_push_config(module: nil, function: :get_config)
      assert PushConfig.to_service_config(config) == nil
    end

    test "returns nil when function is nil" do
      config = valid_push_config(module: SomeModule, function: nil)
      assert PushConfig.to_service_config(config) == nil
    end

    test "returns nil when both are nil" do
      config = valid_push_config(module: nil, function: nil)
      assert PushConfig.to_service_config(config) == nil
    end

    test "ServiceConfig has correct fields populated from PushConfig" do
      config =
        valid_push_config(
          service: "my_service",
          nodes: [:node1@host, :node2@host],
          module: MyModule,
          function: :my_function,
          args: [:arg1, :arg2],
          version_module: VersionModule,
          version_function: :check_version,
          version_args: [:varg1]
        )

      result = PushConfig.to_service_config(config)

      assert %ServiceConfig{} = result
      assert result.service == "my_service"
      assert result.nodes == [:node1@host, :node2@host]
      assert result.module == MyModule
      assert result.function == :my_function
      assert result.args == [:arg1, :arg2]
      assert result.version_module == VersionModule
      assert result.version_function == :check_version
      assert result.version_args == [:varg1]
    end
  end
end
