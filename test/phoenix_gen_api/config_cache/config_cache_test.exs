defmodule PhoenixGenApi.ConfigCacheTest do
  use ExUnit.Case

  alias PhoenixGenApi.ConfigCache
  alias PhoenixGenApi.Structs.FunConfig

  setup do
    # The ConfigCache is already started by the application supervisor.
    # We just need to make sure it's clean before each test.
    :ets.delete_all_objects(PhoenixGenApi.ConfigCache)
    :ok
  end

  test "add/1 and get/1" do
    config = %FunConfig{request_type: "test_request"}
    assert :ok = ConfigCache.add(config)
    assert {:ok, ^config} = ConfigCache.get("test_request")
  end

  test "update/1" do
    config = %FunConfig{request_type: "test_request"}
    assert :ok = ConfigCache.add(config)

    updated_config = %{config | service: :new_service}
    assert :ok = ConfigCache.update(updated_config)

    assert {:ok, ^updated_config} = ConfigCache.get("test_request")
  end

  test "delete/1" do
    config = %FunConfig{request_type: "test_request"}
    assert :ok = ConfigCache.add(config)

    assert :ok = ConfigCache.delete("test_request")
    assert {:error, :not_found} = ConfigCache.get("test_request")
  end

  test "get_all_keys/0" do
    config1 = %FunConfig{request_type: "test_request_1"}
    config2 = %FunConfig{request_type: "test_request_2"}

    assert :ok = ConfigCache.add(config1)
    assert :ok = ConfigCache.add(config2)

    keys = ConfigCache.get_all_keys()
    assert Enum.sort(keys) == ["test_request_1", "test_request_2"]
  end
end
