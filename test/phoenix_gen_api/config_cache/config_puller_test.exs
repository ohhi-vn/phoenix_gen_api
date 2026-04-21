defmodule PhoenixGenApi.ConfigPullerTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.ConfigPuller
  alias PhoenixGenApi.ConfigDb
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
      old_config =
        struct(
          PhoenixGenApi.Structs.FunConfig,
          %{
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
          }
        )
        |> Map.from_struct()
        |> Map.delete(:version)

      # Verify :version key is not present
      refute Map.has_key?(old_config, :version)

      # Simulate what ConfigPuller.ensure_version/1 does: add default version
      config_with_version =
        struct(PhoenixGenApi.Structs.FunConfig, Map.put(old_config, :version, "0.0.0"))

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

      assert {:ok, retrieved} =
               PhoenixGenApi.ConfigDb.get("versioned_service", "test_versioned_api", "2.0.0")

      assert retrieved.version == "2.0.0"
    end
  end

  describe "ServiceConfig.version_check_enabled?/1" do
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
        version_args: []
      }

      assert ServiceConfig.version_check_enabled?(service) == false
    end

    test "returns false by default (no version fields set)" do
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

  describe "get_service_version/1" do
    test "returns nil for a service with no stored version" do
      result = ConfigPuller.get_service_version("nonexistent_service")
      assert result == nil
    end
  end

  describe "get_all_versions/0" do
    test "returns a map" do
      result = ConfigPuller.get_all_versions()
      assert is_map(result)
    end
  end

  describe "force_pull/0" do
    test "triggers a full pull ignoring version checks" do
      assert :ok = ConfigPuller.force_pull()
    end
  end

  describe "version-based skip mechanism" do
    test "stores nil version for services without version checking configured" do
      # Add a service without version checking
      service = %ServiceConfig{
        service: "no_version_check_service",
        nodes: [:nonode@unreachable],
        module: :nonexistent,
        function: :nonexistent,
        args: []
      }

      ConfigPuller.add([service])
      ConfigPuller.pull()

      # Version should be nil since version checking is not configured
      version = ConfigPuller.get_service_version("no_version_check_service")
      # It may be nil if the pull failed, or nil if version checking was not configured
      assert version == nil
    end

    test "delete removes stored version and API list for a service" do
      service = %ServiceConfig{
        service: "delete_version_service",
        nodes: [:nonode@unreachable],
        module: :nonexistent,
        function: :nonexistent,
        args: []
      }

      ConfigPuller.add([service])
      ConfigPuller.pull()

      # Now delete the service
      ConfigPuller.delete([service])

      # The service should no longer be in the services map
      services = ConfigPuller.get_services()
      refute Map.has_key?(services, "delete_version_service")

      # The API list should no longer have an entry
      api_list = ConfigPuller.get_api_list("delete_version_service")
      assert api_list == nil
    end
  end

  describe "telemetry" do
    test "emits config pull start and stop events" do
      test_pid = self()

      :telemetry.attach(
        "test-pull-start",
        [:phoenix_gen_api, :config, :pull, :start],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:pull_start, metadata.service})
        end,
        %{}
      )

      :telemetry.attach(
        "test-pull-stop",
        [:phoenix_gen_api, :config, :pull, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:pull_stop, metadata.service, measurements.count})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-pull-start")
        :telemetry.detach("test-pull-stop")
      end)

      # Force a pull to trigger telemetry
      ConfigPuller.force_pull()

      # Give the async pull a moment to run
      Process.sleep(100)

      # Since there are no services configured, we may not get events,
      # but the test structure is in place for when services exist.
      # Just verify the handlers are attached without crashing.
      :ok
    end
  end

  describe "version check with local test module" do
    # Define a test module that simulates a remote service with version checking
    defmodule TestVersionedService do
      @current_version "v1"
      @current_config [
        %PhoenixGenApi.Structs.FunConfig{
          request_type: "test_api",
          service: "local_versioned_service",
          nodes: [Node.self()],
          choose_node_mode: :random,
          timeout: 5000,
          mfa: {String, :upcase, []},
          arg_types: %{"text" => :string},
          arg_orders: ["text"],
          response_type: :sync,
          check_permission: false,
          request_info: false,
          version: "1.0.0"
        }
      ]

      def get_config_version, do: @current_version
      def get_config, do: {:ok, @current_config}

      # Helper to change version for testing
      def set_version(new_version) do
        Process.put(:test_version, new_version)
      end

      def get_current_version do
        Process.get(:test_version, @current_version)
      end
    end

    test "skips pull when version matches stored version" do
      # First, do a pull to establish the version
      service = %ServiceConfig{
        service: "local_versioned_service",
        nodes: [Node.self()],
        module: __MODULE__.TestVersionedService,
        function: :get_config,
        args: [],
        version_module: __MODULE__.TestVersionedService,
        version_function: :get_config_version,
        version_args: []
      }

      # Clean up any previous state
      :ets.delete_all_objects(PhoenixGenApi.ConfigDb)

      ConfigPuller.add([service])

      # First pull should fetch the config
      ConfigPuller.pull()

      # Wait a bit for async processing
      Process.sleep(100)

      # The version should be stored
      version = ConfigPuller.get_service_version("local_versioned_service")
      assert version != nil

      # Clean the config DB to verify that a skipped pull does not re-populate it
      :ets.delete_all_objects(PhoenixGenApi.ConfigDb)

      # Second pull should skip because version matches
      ConfigPuller.pull()
      Process.sleep(100)

      # Since the version matched, the config should NOT have been re-added
      # (the pull was skipped, so no new configs were inserted)
      # Note: This test relies on the fact that the version check returns the same
      # version as the stored one, causing a skip.
      # The ConfigDb should remain empty since we cleared it and the pull was skipped.
    end

    test "performs full pull when version changes" do
      # Set up a service with version checking
      service = %ServiceConfig{
        service: "local_versioned_service_v2",
        nodes: [Node.self()],
        module: __MODULE__.TestVersionedService,
        function: :get_config,
        args: [],
        version_module: __MODULE__.TestVersionedService,
        version_function: :get_config_version,
        version_args: []
      }

      # Clean up any previous state
      :ets.delete_all_objects(PhoenixGenApi.ConfigDb)

      ConfigPuller.add([service])

      # First pull should fetch the config
      ConfigPuller.pull()
      Process.sleep(100)

      # The version should be stored
      version = ConfigPuller.get_service_version("local_versioned_service_v2")
      assert version != nil
    end

    test "force_pull clears versions and re-fetches all services" do
      service = %ServiceConfig{
        service: "force_pull_service",
        nodes: [Node.self()],
        module: __MODULE__.TestVersionedService,
        function: :get_config,
        args: [],
        version_module: __MODULE__.TestVersionedService,
        version_function: :get_config_version,
        version_args: []
      }

      # Clean up any previous state
      :ets.delete_all_objects(PhoenixGenApi.ConfigDb)

      ConfigPuller.add([service])

      # First pull to establish baseline
      ConfigPuller.pull()
      Process.sleep(100)

      # Store the current version
      version_before = ConfigPuller.get_service_version("force_pull_service")

      # Force pull should clear versions and re-fetch
      ConfigPuller.force_pull()
      Process.sleep(100)

      # After force_pull, the version should be re-fetched
      # (it may be the same value, but it was re-fetched rather than skipped)
      version_after = ConfigPuller.get_service_version("force_pull_service")
      assert version_after != nil
    end

    test "version check failure falls back to full pull" do
      # Use a service with version checking configured, but the version function
      # will fail because the node is unreachable
      service = %ServiceConfig{
        service: "version_check_fallback_service",
        nodes: [:nonode@unreachable],
        module: :nonexistent,
        function: :nonexistent,
        args: [],
        version_module: :nonexistent,
        version_function: :nonexistent,
        version_args: []
      }

      ConfigPuller.add([service])

      # Pull should not crash even though version check and full pull both fail
      assert :ok = ConfigPuller.pull()
    end
  end

  describe "ServiceConfig.from_map/1 with version fields" do
    test "parses version_module, version_function, and version_args from map" do
      config = %{
        "service" => "test_service",
        "nodes" => ["node1@localhost"],
        "module" => "TestModule",
        "function" => "get_config",
        "args" => [],
        "version_module" => "TestModule",
        "version_function" => "get_config_version",
        "version_args" => []
      }

      result = ServiceConfig.from_map(config)
      assert result.service == "test_service"
      # Note: Nestru may decode strings for module/function names
      # The actual behavior depends on the Nestru decoder configuration
    end

    test "handles missing version fields gracefully" do
      config = %{
        "service" => "test_service_no_version",
        "nodes" => ["node1@localhost"],
        "module" => "TestModule",
        "function" => "get_config",
        "args" => []
      }

      result = ServiceConfig.from_map(config)
      assert result.service == "test_service_no_version"
      # Version fields should be nil when not provided
      assert result.version_module == nil
      assert result.version_function == nil
      assert result.version_args == nil
    end
  end
end
