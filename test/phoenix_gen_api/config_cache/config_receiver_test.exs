defmodule PhoenixGenApi.ConfigReceiverTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Structs.{PushConfig, FunConfig}
  alias PhoenixGenApi.{ConfigDb, ConfigReceiver}

  require Logger

  # ConfigDb and ConfigReceiver are already started by the application supervisor

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

  describe "push/1" do
    test "accepts a valid PushConfig and returns {:ok, :accepted}" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)
    end

    test "stores FunConfigs in ConfigDb after push" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      assert {:ok, _fun_config} =
               ConfigDb.get("test_service", "test_request", "1.0.0")
    end

    test "returns {:ok, :skipped, :version_matches} when pushing same version again" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      assert {:ok, :skipped, :version_matches} = ConfigReceiver.push(config)
    end

    test "returns {:ok, :accepted} when pushing with force: true even if version matches" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      assert {:ok, :accepted} = ConfigReceiver.push(config, force: true)
    end

    test "returns {:error, _} for invalid PushConfig (nil service)" do
      config = valid_push_config(service: nil)
      assert {:error, _reason} = ConfigReceiver.push(config)
    end

    test "returns {:error, _} for PushConfig with empty fun_configs" do
      config = valid_push_config(fun_configs: [])
      assert {:error, _reason} = ConfigReceiver.push(config)
    end

    test "accepts a map and decodes it into PushConfig" do
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

      map_config = %{
        service: "test_service",
        nodes: [Node.self()],
        config_version: "1.0.0",
        fun_configs: [fun_config]
      }

      assert {:ok, :accepted} = ConfigReceiver.push(map_config)
    end

    test "returns {:error, _} for invalid data type (not map or PushConfig)" do
      assert {:error, _reason} = ConfigReceiver.push("invalid")
      assert {:error, _reason} = ConfigReceiver.push(123)
      assert {:error, _reason} = ConfigReceiver.push(nil)
    end
  end

  describe "push/2 with force" do
    test "force push accepts even when version matches" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      # Same version without force should be skipped
      assert {:ok, :skipped, :version_matches} = ConfigReceiver.push(config, force: false)

      # Same version with force should be accepted
      assert {:ok, :accepted} = ConfigReceiver.push(config, force: true)
    end
  end

  describe "verify/2" do
    test "returns {:ok, :matched} when version matches" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      assert {:ok, :matched} = ConfigReceiver.verify("test_service", "1.0.0")
    end

    test "returns {:ok, :mismatch, stored_version} when version differs" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      assert {:ok, :mismatch, "1.0.0"} = ConfigReceiver.verify("test_service", "2.0.0")
    end

    test "returns {:error, :not_found} when service not known" do
      assert {:error, :not_found} = ConfigReceiver.verify("unknown_service", "1.0.0")
    end
  end

  describe "get_pushed_config/1" do
    test "returns the PushConfig for a known service" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      result = ConfigReceiver.get_pushed_config("test_service")
      assert %PushConfig{} = result
      assert result.service == "test_service"
      assert result.config_version == "1.0.0"
    end

    test "returns nil for unknown service" do
      assert nil == ConfigReceiver.get_pushed_config("unknown_service")
    end
  end

  describe "get_all_pushed_services/0" do
    test "returns empty map when no services pushed" do
      assert %{} == ConfigReceiver.get_all_pushed_services()
    end

    test "returns map of service => version after push" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      result = ConfigReceiver.get_all_pushed_services()
      assert %{"test_service" => "1.0.0"} = result
    end
  end

  describe "delete_pushed_service/1" do
    test "removes service from receiver state" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      assert :ok = ConfigReceiver.delete_pushed_service("test_service")
      assert nil == ConfigReceiver.get_pushed_config("test_service")
      assert %{} == ConfigReceiver.get_all_pushed_services()
    end

    test "returns :ok for unknown service too" do
      assert :ok = ConfigReceiver.delete_pushed_service("unknown_service")
    end
  end

  describe "integration: push stores in ConfigDb" do
    test "after push, FunConfig is retrievable from ConfigDb" do
      config = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config)

      assert {:ok, stored} = ConfigDb.get("test_service", "test_request", "1.0.0")
      assert %FunConfig{} = stored
      assert stored.request_type == "test_request"
      assert stored.service == "test_service"
    end

    test "after push with new version, new FunConfig is in ConfigDb" do
      config_v1 = valid_push_config()
      assert {:ok, :accepted} = ConfigReceiver.push(config_v1)

      # Push a new version
      fun_config_v2 = %FunConfig{
        request_type: "test_request",
        service: "test_service",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 10000,
        mfa: {String, :downcase, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        version: "2.0.0"
      }

      config_v2 = valid_push_config(config_version: "2.0.0", fun_configs: [fun_config_v2])
      assert {:ok, :accepted} = ConfigReceiver.push(config_v2)

      # Both versions should be in ConfigDb
      assert {:ok, stored_v1} = ConfigDb.get("test_service", "test_request", "1.0.0")
      assert {:ok, stored_v2} = ConfigDb.get("test_service", "test_request", "2.0.0")

      assert stored_v1.version == "1.0.0"
      assert stored_v2.version == "2.0.0"
      assert stored_v2.timeout == 10000
    end
  end

  describe "telemetry" do
    test "emits config push telemetry event" do
      test_pid = self()

      :telemetry.attach(
        "test-config-push-handler",
        [:phoenix_gen_api, :config, :push],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:config_push, measurements.count, metadata.service, metadata.version})
        end,
        %{}
      )

      on_exit(fn ->
        :telemetry.detach("test-config-push-handler")
      end)

      fun_config = %FunConfig{
        request_type: "test_request",
        service: "TelemetryService",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {String, :upcase, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :sync,
        version: "1.5.0"
      }

      config =
        valid_push_config(%{
          service: "TelemetryService",
          config_version: "1.5.0",
          fun_configs: [fun_config]
        })

      assert {:ok, :accepted} = ConfigReceiver.push(config)

      assert_receive {:config_push, 1, "TelemetryService", "1.5.0"}, 1000
    end
  end
end
