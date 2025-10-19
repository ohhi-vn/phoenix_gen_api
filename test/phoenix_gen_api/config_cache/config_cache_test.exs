defmodule PhoenixGenApi.ConfigDbTest do
  use ExUnit.Case

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Structs.FunConfig

  setup do
    # The ConfigDb is already started by the application supervisor.
    # We just need to make sure it's clean before each test.
    :ets.delete_all_objects(PhoenixGenApi.ConfigDb)
    :ok
  end

  test "add/1 and get/1" do
    config = %FunConfig{service: "Test", request_type: "test_request"}
    assert :ok = ConfigDb.add(config)
    assert {:ok, ^config} = ConfigDb.get("Test", "test_request")
  end

  test "update/1" do
    config = %FunConfig{service: "Test", request_type: "test_request"}
    assert :ok = ConfigDb.add(config)

    updated_config = %FunConfig{config | service: "new_service"}
    assert :ok = ConfigDb.update(updated_config)

    assert {:ok, ^updated_config} = ConfigDb.get("new_service", "test_request")
  end

  test "delete/1" do
    config = %FunConfig{service: "Test", request_type: "test_request"}
    assert :ok = ConfigDb.add(config)

    assert :ok = ConfigDb.delete("Test", "test_request")
    assert {:error, :not_found} = ConfigDb.get("Test", "test_request")
  end

  test "get_all_functions/0" do
    config1 = %FunConfig{service: "Test1", request_type: "test_request_1"}

    assert :ok = ConfigDb.add(config1)

    assert %{"Test1" => ["test_request_1"]} == ConfigDb.get_all_functions()
  end

  test "get_all_services/0" do
    config1 = %FunConfig{service: "Test1", request_type: "test_request_1"}
    config2 = %FunConfig{service: "Test2", request_type: "test_request_2"}

    assert :ok = ConfigDb.add(config1)
    assert :ok = ConfigDb.add(config2)

    keys = ConfigDb.get_all_services()
    assert Enum.member?(keys, "Test1")
    assert Enum.member?(keys, "Test2")
  end
end
