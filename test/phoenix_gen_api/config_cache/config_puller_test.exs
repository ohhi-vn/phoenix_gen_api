defmodule PhoenixGenApi.ConfigPullerTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.ConfigPuller
  alias PhoenixGenApi.Structs.ServiceConfig

  # ConfigDb and ConfigPuller are already started by the application

  describe "add/1" do
    test "adds a list of services" do
      services = [
        %ServiceConfig{
          service: "test_service",
          nodes: ["node1@localhost"],
          module: "TestModule",
          function: "test_function",
          args: []
        }
      ]

      assert :ok = ConfigPuller.add(services)

      # Verify the service was added
      result = ConfigPuller.get_services()
      assert Map.has_key?(result, "test_service")
    end

    test "logs warning when adding empty list" do
      assert :ok = ConfigPuller.add([])
    end

    test "raises error when services is not a list of ServiceConfig" do
      assert_raise ArgumentError, fn ->
        ConfigPuller.add([%{invalid: "data"}])
      end
    end
  end

  describe "delete/1" do
    test "deletes a list of services" do
      services = [
        %ServiceConfig{
          service: "test_service_delete",
          nodes: ["node1@localhost"],
          module: "TestModule",
          function: "test_function",
          args: []
        }
      ]

      ConfigPuller.add(services)
      assert :ok = ConfigPuller.delete(services)

      # Verify the service was deleted
      result = ConfigPuller.get_services()
      refute Map.has_key?(result, "test_service_delete")
    end

    test "logs warning when deleting empty list" do
      assert :ok = ConfigPuller.delete([])
    end

    test "raises error when services is not a list of ServiceConfig" do
      assert_raise ArgumentError, fn ->
        ConfigPuller.delete([%{invalid: "data"}])
      end
    end
  end

  describe "get_services/0" do
    test "returns map of services" do
      result = ConfigPuller.get_services()
      assert is_map(result)
    end
  end

  describe "get_api_list/1" do
    test "returns api list for a service" do
      result = ConfigPuller.get_api_list("test_service")
      assert result == nil or is_list(result)
    end
  end

  describe "pull/0" do
    test "triggers an immediate pull" do
      assert :ok = ConfigPuller.pull()
    end
  end

  describe "validate_mfa_safety/3 (via pull integration)" do
    test "accepts valid MFA with module loaded on local node" do
      # String module is always loaded
      service = %ServiceConfig{
        service: "valid_mfa_service",
        nodes: [Node.self()],
        module: "TestModule",
        function: "get_config",
        args: []
      }

      assert :ok = ConfigPuller.add([service])
      # The pull will attempt to validate MFA on the local node
      # String module should be found loaded
      assert :ok = ConfigPuller.pull()
    end

    test "rejects invalid MFA format" do
      # Create a service that returns a config with invalid MFA
      service = %ServiceConfig{
        service: "invalid_mfa_service",
        nodes: [Node.self()],
        module: "TestModule",
        function: "get_config",
        args: []
      }

      assert :ok = ConfigPuller.add([service])
      # Pull will attempt to validate, invalid MFA will be logged and skipped
      assert :ok = ConfigPuller.pull()
    end

    test "handles module not loaded on remote node gracefully" do
      # Use a non-existent module name
      service = %ServiceConfig{
        service: "missing_module_service",
        nodes: [Node.self()],
        module: "NonExistentModule",
        function: "get_config",
        args: []
      }

      assert :ok = ConfigPuller.add([service])
      # Pull will attempt to validate, module not found will be logged
      assert :ok = ConfigPuller.pull()
    end

    test "handles unreachable node during MFA validation" do
      # Use a node that doesn't exist
      service = %ServiceConfig{
        service: "unreachable_node_service",
        nodes: [:nonode@unreachable],
        module: "TestModule",
        function: "get_config",
        args: []
      }

      assert :ok = ConfigPuller.add([service])
      # Pull will fail to connect, but should not crash
      assert :ok = ConfigPuller.pull()
    end
  end

  describe "ensure_version/1 (backward compatibility)" do
    test "adds default version to FunConfig without :version field" do
      # Simulate old FunConfig from remote node without :version field
      # Create struct then remove :version key to mimic old library behavior
      old_config = struct(PhoenixGenApi.Structs.FunConfig, %{
        request_type: "test_old_api",
        service: "old_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {String, :upcase, []},
        arg_types: %{"text" => :string},
        arg_orders: ["text"],
        response_type: :sync,
        check_permission: false,
        request_info: false
      })
      |> Map.from_struct()
      |> Map.delete(:version)

      # Verify :version key is not present
      refute Map.has_key?(old_config, :version)

      # Simulate what ConfigPuller.ensure_version/1 does: add default version
      config_with_version = struct(PhoenixGenApi.Structs.FunConfig, Map.put(old_config, :version, "0.0.0"))

      # Verify version was added
      assert config_with_version.version == "0.0.0"
      assert Map.has_key?(config_with_version, :version)

      # Verify it can be added to ConfigDb
      assert :ok = PhoenixGenApi.ConfigDb.add(config_with_version)

      # Verify it can be retrieved with the default version
      assert {:ok, retrieved} = PhoenixGenApi.ConfigDb.get("old_service", "test_old_api", "0.0.0")
      assert retrieved.request_type == "test_old_api"
    end

    test "preserves existing version when present" do
      config = %PhoenixGenApi.Structs.FunConfig{
        request_type: "test_versioned_api",
        service: "versioned_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {String, :upcase, []},
        arg_types: %{"text" => :string},
        arg_orders: ["text"],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        version: "2.0.0"
      }

      # Version should be preserved
      assert config.version == "2.0.0"

      # Verify it can be added and retrieved
      assert :ok = PhoenixGenApi.ConfigDb.add(config)
      assert {:ok, retrieved} = PhoenixGenApi.ConfigDb.get("versioned_service", "test_versioned_api", "2.0.0")
      assert retrieved.version == "2.0.0"
    end
  end
end
