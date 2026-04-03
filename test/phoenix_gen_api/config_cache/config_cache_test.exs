defmodule PhoenixGenApi.ConfigDbTest do
  use ExUnit.Case

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Structs.FunConfig

  defp valid_config(overrides \\ %{}) do
    defaults = %{
      service: "Test",
      request_type: "test_request",
      nodes: [Node.self()],
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {String, :upcase, []},
      arg_types: %{},
      arg_orders: [],
      response_type: :sync,
      check_permission: false,
      request_info: false,
      version: "0.0.0"
    }

    struct(FunConfig, Map.merge(defaults, overrides))
  end

  setup do
    # The ConfigDb is already started by the application supervisor.
    # We just need to make sure it's clean before each test.
    :ets.delete_all_objects(PhoenixGenApi.ConfigDb)
    :ok
  end

  test "add/1 and get/2" do
    config = valid_config()
    assert :ok = ConfigDb.add(config)
    assert {:ok, ^config} = ConfigDb.get("Test", "test_request", "0.0.0")
  end

  test "add/1 and get/2 with custom version" do
    config = valid_config(%{version: "1.0.0"})
    assert :ok = ConfigDb.add(config)
    assert {:ok, ^config} = ConfigDb.get("Test", "test_request", "1.0.0")
    assert {:error, :not_found} = ConfigDb.get("Test", "test_request", "0.0.0")
  end

  test "update/1" do
    config = valid_config()
    assert :ok = ConfigDb.add(config)

    updated_config = valid_config(%{service: "new_service"})
    assert :ok = ConfigDb.update(updated_config)

    assert {:ok, ^updated_config} = ConfigDb.get("new_service", "test_request", "0.0.0")
  end

  test "delete/2" do
    config = valid_config()
    assert :ok = ConfigDb.add(config)

    assert :ok = ConfigDb.delete("Test", "test_request", "0.0.0")
    assert {:error, :not_found} = ConfigDb.get("Test", "test_request", "0.0.0")
  end

  test "delete/2 with custom version" do
    config1 = valid_config(%{version: "1.0.0"})
    config2 = valid_config(%{version: "2.0.0"})
    assert :ok = ConfigDb.add(config1)
    assert :ok = ConfigDb.add(config2)

    assert :ok = ConfigDb.delete("Test", "test_request", "1.0.0")
    assert {:error, :not_found} = ConfigDb.get("Test", "test_request", "1.0.0")
    assert {:ok, ^config2} = ConfigDb.get("Test", "test_request", "2.0.0")
  end

  test "get_all_functions/0" do
    config1 = valid_config(%{service: "Test1", request_type: "test_request_1"})

    assert :ok = ConfigDb.add(config1)

    assert %{"Test1" => %{"test_request_1" => ["0.0.0"]}} == ConfigDb.get_all_functions()
  end

  test "get_all_functions/0 with multiple versions" do
    config1 = valid_config(%{service: "Test1", request_type: "test_request_1", version: "1.0.0"})
    config2 = valid_config(%{service: "Test1", request_type: "test_request_1", version: "2.0.0"})

    assert :ok = ConfigDb.add(config1)
    assert :ok = ConfigDb.add(config2)

    result = ConfigDb.get_all_functions()
    assert Map.has_key?(result, "Test1")
    assert Map.has_key?(result["Test1"], "test_request_1")
    assert "1.0.0" in result["Test1"]["test_request_1"]
    assert "2.0.0" in result["Test1"]["test_request_1"]
  end

  test "get_all_services/0" do
    config1 = valid_config(%{service: "Test1", request_type: "test_request_1"})
    config2 = valid_config(%{service: "Test2", request_type: "test_request_2"})

    assert :ok = ConfigDb.add(config1)
    assert :ok = ConfigDb.add(config2)

    keys = ConfigDb.get_all_services()
    assert Enum.member?(keys, "Test1")
    assert Enum.member?(keys, "Test2")
  end

  test "disable/3 and enable/3" do
    config = valid_config()
    assert :ok = ConfigDb.add(config)

    # Test disable
    assert :ok = ConfigDb.disable("Test", "test_request", "0.0.0")
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "0.0.0")

    # Test enable
    assert :ok = ConfigDb.enable("Test", "test_request", "0.0.0")
    assert {:ok, ^config} = ConfigDb.get("Test", "test_request", "0.0.0")
  end

  test "disable/3 returns error for non-existent config" do
    assert {:error, :not_found} = ConfigDb.disable("Test", "nonexistent", "0.0.0")
  end

  test "enable/3 returns error for non-existent config" do
    assert {:error, :not_found} = ConfigDb.enable("Test", "nonexistent", "0.0.0")
  end

  test "get_latest/2 returns latest version" do
    config1 = valid_config(%{version: "1.0.0"})
    config2 = valid_config(%{version: "2.0.0"})
    config3 = valid_config(%{version: "1.5.0"})

    assert :ok = ConfigDb.add(config1)
    assert :ok = ConfigDb.add(config2)
    assert :ok = ConfigDb.add(config3)

    assert {:ok, latest} = ConfigDb.get_latest("Test", "test_request")
    assert latest.version == "2.0.0"
  end

  test "get_latest/2 skips disabled configs" do
    config1 = valid_config(%{version: "1.0.0"})
    config2 = valid_config(%{version: "2.0.0"})

    assert :ok = ConfigDb.add(config1)
    assert :ok = ConfigDb.add(config2)

    # Disable the latest version
    assert :ok = ConfigDb.disable("Test", "test_request", "2.0.0")

    # Should return the next latest enabled version
    assert {:ok, latest} = ConfigDb.get_latest("Test", "test_request")
    assert latest.version == "1.0.0"
  end

  test "get/2 returns not_found for unsupported version" do
    config = valid_config(%{version: "1.0.0"})
    assert :ok = ConfigDb.add(config)

    # Requesting a version that doesn't exist should return not_found
    assert {:error, :not_found} = ConfigDb.get("Test", "test_request", "2.0.0")
    assert {:error, :not_found} = ConfigDb.get("Test", "test_request", "0.0.0")
    assert {:error, :not_found} = ConfigDb.get("Test", "test_request", "99.99.99")
  end

  test "get/2 with empty version string defaults to 0.0.0" do
    config = valid_config(%{version: "0.0.0"})
    assert :ok = ConfigDb.add(config)

    # Empty version should default to "0.0.0"
    assert {:ok, ^config} = ConfigDb.get("Test", "test_request", "0.0.0")
  end

  test "multiple versions coexist independently" do
    config_v1 = valid_config(%{version: "1.0.0", timeout: 5000})
    config_v2 = valid_config(%{version: "2.0.0", timeout: 10000})
    config_v3 = valid_config(%{version: "3.0.0", timeout: 15000})

    assert :ok = ConfigDb.add(config_v1)
    assert :ok = ConfigDb.add(config_v2)
    assert :ok = ConfigDb.add(config_v3)

    # Each version should be retrievable independently
    assert {:ok, retrieved_v1} = ConfigDb.get("Test", "test_request", "1.0.0")
    assert retrieved_v1.timeout == 5000

    assert {:ok, retrieved_v2} = ConfigDb.get("Test", "test_request", "2.0.0")
    assert retrieved_v2.timeout == 10000

    assert {:ok, retrieved_v3} = ConfigDb.get("Test", "test_request", "3.0.0")
    assert retrieved_v3.timeout == 15000
  end

  test "disable/3 only affects specified version" do
    config_v1 = valid_config(%{version: "1.0.0"})
    config_v2 = valid_config(%{version: "2.0.0"})
    config_v3 = valid_config(%{version: "3.0.0"})

    assert :ok = ConfigDb.add(config_v1)
    assert :ok = ConfigDb.add(config_v2)
    assert :ok = ConfigDb.add(config_v3)

    # Disable only version 2.0.0
    assert :ok = ConfigDb.disable("Test", "test_request", "2.0.0")

    # Version 2.0.0 should be disabled
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "2.0.0")

    # Other versions should still be accessible
    assert {:ok, ^config_v1} = ConfigDb.get("Test", "test_request", "1.0.0")
    assert {:ok, ^config_v3} = ConfigDb.get("Test", "test_request", "3.0.0")
  end

  test "disable/3 persists state after multiple operations" do
    config = valid_config(%{version: "1.0.0"})
    assert :ok = ConfigDb.add(config)

    # Disable the config
    assert :ok = ConfigDb.disable("Test", "test_request", "1.0.0")
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "1.0.0")

    # Add another version
    config_v2 = valid_config(%{version: "2.0.0"})
    assert :ok = ConfigDb.add(config_v2)

    # Original config should still be disabled
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "1.0.0")
    assert {:ok, ^config_v2} = ConfigDb.get("Test", "test_request", "2.0.0")
  end

  test "enable/3 restores disabled config" do
    config = valid_config(%{version: "1.0.0"})
    assert :ok = ConfigDb.add(config)

    # Disable the config
    assert :ok = ConfigDb.disable("Test", "test_request", "1.0.0")
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "1.0.0")

    # Enable the config
    assert :ok = ConfigDb.enable("Test", "test_request", "1.0.0")

    # Config should be accessible again
    assert {:ok, ^config} = ConfigDb.get("Test", "test_request", "1.0.0")
  end

  test "disable/3 and enable/3 with multiple versions" do
    config_v1 = valid_config(%{version: "1.0.0"})
    config_v2 = valid_config(%{version: "2.0.0"})

    assert :ok = ConfigDb.add(config_v1)
    assert :ok = ConfigDb.add(config_v2)

    # Disable version 1.0.0
    assert :ok = ConfigDb.disable("Test", "test_request", "1.0.0")
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "1.0.0")
    assert {:ok, ^config_v2} = ConfigDb.get("Test", "test_request", "2.0.0")

    # Disable version 2.0.0
    assert :ok = ConfigDb.disable("Test", "test_request", "2.0.0")
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "2.0.0")

    # Both should be disabled
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "1.0.0")
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "2.0.0")

    # get_latest should return not_found when all versions are disabled
    assert {:error, :not_found} = ConfigDb.get_latest("Test", "test_request")

    # Enable version 2.0.0
    assert :ok = ConfigDb.enable("Test", "test_request", "2.0.0")
    assert {:ok, ^config_v2} = ConfigDb.get("Test", "test_request", "2.0.0")
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "1.0.0")
  end

  test "get_latest/2 returns not_found when no versions exist" do
    assert {:error, :not_found} = ConfigDb.get_latest("Test", "nonexistent_request")
  end

  test "get_latest/2 returns not_found when only disabled versions exist" do
    config_v1 = valid_config(%{version: "1.0.0"})
    config_v2 = valid_config(%{version: "2.0.0"})

    assert :ok = ConfigDb.add(config_v1)
    assert :ok = ConfigDb.add(config_v2)

    # Disable all versions
    assert :ok = ConfigDb.disable("Test", "test_request", "1.0.0")
    assert :ok = ConfigDb.disable("Test", "test_request", "2.0.0")

    # get_latest should return not_found
    assert {:error, :not_found} = ConfigDb.get_latest("Test", "test_request")
  end

  test "get_all_functions/0 with mixed enabled and disabled versions" do
    config_v1 = valid_config(%{service: "Test1", request_type: "test_request_1", version: "1.0.0"})
    config_v2 = valid_config(%{service: "Test1", request_type: "test_request_1", version: "2.0.0"})

    assert :ok = ConfigDb.add(config_v1)
    assert :ok = ConfigDb.add(config_v2)

    # Disable version 1.0.0
    assert :ok = ConfigDb.disable("Test1", "test_request_1", "1.0.0")

    # get_all_functions should still list all versions
    result = ConfigDb.get_all_functions()
    assert Map.has_key?(result, "Test1")
    assert Map.has_key?(result["Test1"], "test_request_1")
    assert "1.0.0" in result["Test1"]["test_request_1"]
    assert "2.0.0" in result["Test1"]["test_request_1"]
  end

  test "version validation rejects invalid versions" do
    # Empty version should be invalid
    invalid_config = valid_config(%{version: ""})
    assert FunConfig.valid?(invalid_config) == false

    # nil version should be invalid
    invalid_config_nil = valid_config(%{version: nil})
    assert FunConfig.valid?(invalid_config_nil) == false
  end

  test "disabled field defaults to false" do
    config = valid_config()
    assert config.disabled == false
  end

  test "disable/3 sets disabled field to true" do
    config = valid_config(%{version: "1.0.0"})
    assert :ok = ConfigDb.add(config)

    assert :ok = ConfigDb.disable("Test", "test_request", "1.0.0")
    assert {:error, :disabled} = ConfigDb.get("Test", "test_request", "1.0.0")

    # Verify the disabled field is set
    case :ets.lookup(PhoenixGenApi.ConfigDb, {"Test", "test_request", "1.0.0"}) do
      [{_key, stored_config}] ->
        assert stored_config.disabled == true

      [] ->
        flunk("Config not found in ETS")
    end
  end

  test "enable/3 sets disabled field to false" do
    config = valid_config(%{version: "1.0.0"})
    assert :ok = ConfigDb.add(config)

    # Disable then enable
    assert :ok = ConfigDb.disable("Test", "test_request", "1.0.0")
    assert :ok = ConfigDb.enable("Test", "test_request", "1.0.0")

    # Verify the disabled field is set to false
    case :ets.lookup(PhoenixGenApi.ConfigDb, {"Test", "test_request", "1.0.0"}) do
      [{_key, stored_config}] ->
        assert stored_config.disabled == false

      [] ->
        flunk("Config not found in ETS")
    end
  end
end
