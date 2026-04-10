defmodule PhoenixGenApi.Structs.ServiceConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.ServiceConfig

  describe "from_map/1" do
    test "decodes valid service config map" do
      config_map = %{
        "service" => "test_service",
        "nodes" => ["node1@localhost", "node2@localhost"],
        "module" => "TestModule",
        "function" => "test_function",
        "args" => [1, 2, 3]
      }

      config = ServiceConfig.from_map(config_map)

      assert config.service == "test_service"
      assert config.nodes == ["node1@localhost", "node2@localhost"]
      assert config.module == "TestModule"
      assert config.function == "test_function"
      assert config.args == [1, 2, 3]
    end

    test "handles atom keys" do
      config_map = %{
        service: "test_service",
        nodes: ["node1@localhost"],
        module: "TestModule",
        function: "test_function",
        args: []
      }

      config = ServiceConfig.from_map(config_map)

      assert config.service == "test_service"
      assert config.nodes == ["node1@localhost"]
    end

    test "decodes service config with version fields" do
      config_map = %{
        "service" => "versioned_service",
        "nodes" => ["node1@localhost"],
        "module" => "TestModule",
        "function" => "get_config",
        "args" => [],
        "version_module" => "TestModule",
        "version_function" => "get_config_version",
        "version_args" => []
      }

      config = ServiceConfig.from_map(config_map)

      assert config.service == "versioned_service"
      assert config.version_module == "TestModule"
      assert config.version_function == "get_config_version"
      assert config.version_args == []
    end

    test "handles missing version fields gracefully" do
      config_map = %{
        "service" => "unversioned_service",
        "nodes" => ["node1@localhost"],
        "module" => "TestModule",
        "function" => "get_config",
        "args" => []
      }

      config = ServiceConfig.from_map(config_map)

      assert config.service == "unversioned_service"
      assert config.version_module == nil
      assert config.version_function == nil
      assert config.version_args == nil
    end
  end

  describe "version_check_enabled?/1" do
    test "returns true when version_module and version_function are set" do
      service = %ServiceConfig{
        service: "versioned_service",
        nodes: [Node.self()],
        module: SomeModule,
        function: :get_config,
        args: [],
        version_module: SomeModule,
        version_function: :get_config_version,
        version_args: []
      }

      assert ServiceConfig.version_check_enabled?(service) == true
    end

    test "returns true when version_module and version_function are set without version_args" do
      service = %ServiceConfig{
        service: "versioned_service",
        nodes: [Node.self()],
        module: SomeModule,
        function: :get_config,
        args: [],
        version_module: SomeModule,
        version_function: :get_config_version
      }

      assert ServiceConfig.version_check_enabled?(service) == true
    end

    test "returns false when version_module is nil" do
      service = %ServiceConfig{
        service: "unversioned_service",
        nodes: [Node.self()],
        module: SomeModule,
        function: :get_config,
        args: [],
        version_module: nil,
        version_function: :get_config_version,
        version_args: []
      }

      assert ServiceConfig.version_check_enabled?(service) == false
    end

    test "returns false when version_function is nil" do
      service = %ServiceConfig{
        service: "unversioned_service",
        nodes: [Node.self()],
        module: SomeModule,
        function: :get_config,
        args: [],
        version_module: SomeModule,
        version_function: nil,
        version_args: []
      }

      assert ServiceConfig.version_check_enabled?(service) == false
    end

    test "returns false when both version_module and version_function are nil" do
      service = %ServiceConfig{
        service: "unversioned_service",
        nodes: [Node.self()],
        module: SomeModule,
        function: :get_config,
        args: [],
        version_module: nil,
        version_function: nil,
        version_args: nil
      }

      assert ServiceConfig.version_check_enabled?(service) == false
    end

    test "returns false by default when no version fields are set" do
      service = %ServiceConfig{
        service: "default_service",
        nodes: [Node.self()],
        module: SomeModule,
        function: :get_config,
        args: []
      }

      assert ServiceConfig.version_check_enabled?(service) == false
    end
  end
end
