defmodule PhoenixGenApi.ConfigPullerTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.ConfigPuller
  alias PhoenixGenApi.Structs.ServiceConfig

  # ConfigCache and ConfigPuller are already started by the application

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
end
