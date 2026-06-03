defmodule PhoenixGenApi.ExecutorTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.Structs.{Request, FunConfig}
  alias PhoenixGenApi.ConfigDb

  # ConfigDb is already started by the application

  setup do
    unique = System.unique_integer([:positive])

    request = %Request{
      request_id: "test_request_id_#{unique}",
      request_type: "test_sync_#{unique}",
      user_id: "user_123",
      device_id: "device_456",
      args: %{"name" => "Alice", "age" => 30}
    }

    on_exit(fn ->
      ConfigDb.delete("test_service", "test_sync_#{unique}")
    end)

    {:ok, request: request, unique: unique}
  end

  describe "execute!/1" do
    test "returns error when function config not found" do
      unique = System.unique_integer([:positive])

      request = %Request{
        request_id: "test_no_function_req_#{unique}",
        request_type: "test_no_function_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Alice", "age" => 30}
      }

      result = Executor.execute!(request)

      assert result.success == false
      assert result.error =~ "unsupported function"
    end

    test "returns error when requesting unsupported version" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_versioned_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        version: "1.0.0"
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_versioned_#{unique}")
      end)

      # Request with a different version that doesn't exist
      request = %Request{
        request_id: "test_version_req_#{unique}",
        request_type: "test_versioned_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Alice", "age" => 30},
        version: "2.0.0"
      }

      result = Executor.execute!(request)

      assert result.success == false
      assert result.error =~ "unsupported function"
      assert result.error =~ "2.0.0"
    end

    test "executes successfully with matching version" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_versioned_match_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        version: "1.5.0"
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_versioned_match_#{unique}")
      end)

      request = %Request{
        request_id: "test_version_match_req_#{unique}",
        request_type: "test_versioned_match_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Bob", "age" => 25},
        version: "1.5.0"
      }

      result = Executor.execute!(request)

      assert result.success == true
      assert result.result == "Hello Bob, age 25"
    end

    test "returns error when function is disabled" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_disabled_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        version: "1.0.0"
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_disabled_#{unique}")
      end)

      # Disable the function
      assert :ok = ConfigDb.disable("test_service_#{unique}", "test_disabled_#{unique}", "1.0.0")

      request = %Request{
        request_id: "test_disabled_req_#{unique}",
        request_type: "test_disabled_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Charlie", "age" => 30},
        version: "1.0.0"
      }

      result = Executor.execute!(request)

      assert result.success == false
      assert result.error =~ "disabled function"
      assert result.error =~ "1.0.0"
    end

    test "can execute after re-enabling disabled function" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_reenable_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        version: "1.0.0"
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_reenable_#{unique}")
      end)

      # Disable then re-enable
      assert :ok = ConfigDb.disable("test_service_#{unique}", "test_reenable_#{unique}", "1.0.0")
      assert :ok = ConfigDb.enable("test_service_#{unique}", "test_reenable_#{unique}", "1.0.0")

      request = %Request{
        request_id: "test_reenable_req_#{unique}",
        request_type: "test_reenable_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Dave", "age" => 28},
        version: "1.0.0"
      }

      result = Executor.execute!(request)

      assert result.success == true
      assert result.result == "Hello Dave, age 28"
    end

    test "disabling one version does not affect other versions" do
      unique = System.unique_integer([:positive])

      config_v1 = %FunConfig{
        request_type: "test_multi_version_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        version: "1.0.0"
      }

      config_v2 = %FunConfig{
        request_type: "test_multi_version_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        version: "2.0.0"
      }

      ConfigDb.add(config_v1)
      ConfigDb.add(config_v2)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_multi_version_#{unique}")
      end)

      # Disable version 1.0.0
      assert :ok =
               ConfigDb.disable("test_service_#{unique}", "test_multi_version_#{unique}", "1.0.0")

      # Version 1.0.0 should be disabled
      request_v1 = %Request{
        request_id: "test_v1_req_#{unique}",
        request_type: "test_multi_version_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Eve", "age" => 22},
        version: "1.0.0"
      }

      result_v1 = Executor.execute!(request_v1)
      assert result_v1.success == false
      assert result_v1.error =~ "disabled function"

      # Version 2.0.0 should still work
      request_v2 = %Request{
        request_id: "test_v2_req_#{unique}",
        request_type: "test_multi_version_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Frank", "age" => 35},
        version: "2.0.0"
      }

      result_v2 = Executor.execute!(request_v2)
      assert result_v2.success == true
      assert result_v2.result == "Hello Frank, age 35"
    end

    test "defaults to nil version when version is nil in request" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_default_version_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        version: nil
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_default_version_#{unique}")
      end)

      # Request without version (nil) should use get_fast to find the unversioned config
      request = %Request{
        request_id: "test_default_version_req_#{unique}",
        request_type: "test_default_version_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Grace", "age" => 40},
        version: nil
      }

      result = Executor.execute!(request)

      assert result.success == true
      assert result.result == "Hello Grace, age 40"
    end

    test "executes sync call successfully" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_sync_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_sync_#{unique}")
      end)

      request = %Request{
        request_id: "test_sync_req_#{unique}",
        request_type: "test_sync_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Alice", "age" => 30}
      }

      result = Executor.execute!(request)

      assert result.success == true
      assert result.result == "Hello Alice, age 30"
    end

    test "executes sync call with request_info" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_sync_with_info_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_with_info, []},
        arg_types: %{"name" => :string},
        arg_orders: ["name"],
        response_type: :sync,
        check_permission: false,
        request_info: true
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_sync_with_info_#{unique}")
      end)

      request = %Request{
        request_id: "test_sync_req_info_#{unique}",
        request_type: "test_sync_with_info_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Bob"}
      }

      result = Executor.execute!(request)

      assert result.success == true
      assert result.result =~ "Bob"
      assert result.result =~ "user_123"
    end

    test "handles error result from function" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_error_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_error_function, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_error_#{unique}")
      end)

      request = %Request{
        request_id: "test_error_req_#{unique}",
        request_type: "test_error_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
      assert result.error =~ "Internal Server Error"
    end

    test "executes async call" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_async_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :async,
        check_permission: false,
        request_info: false
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_async_#{unique}")
      end)

      request = %Request{
        request_id: "test_async_req_#{unique}",
        request_type: "test_async_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Charlie", "age" => 25}
      }

      result = Executor.execute!(request)

      assert result.async == true
      assert result.success == true
    end

    test "executes none response type (fire and forget)" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_none_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :none,
        check_permission: false,
        request_info: false
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_none_#{unique}")
      end)

      request = %Request{
        request_id: "test_none_req_#{unique}",
        request_type: "test_none_#{unique}",
        service: "test_service_#{unique}",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Dave", "age" => 35}
      }

      result = Executor.execute!(request)

      assert result == {:ok, :no_response}
    end
  end

  describe "execute_params!/1" do
    test "executes from params map" do
      unique = System.unique_integer([:positive])

      config = %FunConfig{
        request_type: "test_params_#{unique}",
        service: "test_service_#{unique}",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :test_sync_function, []},
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"],
        response_type: :sync,
        check_permission: false,
        request_info: false
      }

      ConfigDb.add(config)

      on_exit(fn ->
        ConfigDb.delete("test_service_#{unique}", "test_params_#{unique}")
      end)

      params = %{
        "request_id" => "test_params_req_#{unique}",
        "request_type" => "test_params_#{unique}",
        "service" => "test_service_#{unique}",
        "user_id" => "user_123",
        "device_id" => "device_456",
        "args" => %{"name" => "Eve", "age" => 28}
      }

      result = Executor.execute_params!(params)

      assert result.success == true
      assert result.result == "Hello Eve, age 28"
    end
  end

  test "executes sync call with list string" do
    unique = System.unique_integer([:positive])

    config = %FunConfig{
      request_type: "test_sync_list_#{unique}",
      service: "test_service_#{unique}",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :test_length_list, []},
      arg_types: %{"list" => :list_string},
      arg_orders: ["list"],
      response_type: :sync,
      check_permission: false,
      request_info: false
    }

    ConfigDb.add(config)

    on_exit(fn ->
      ConfigDb.delete("test_service_#{unique}", "test_sync_list_#{unique}")
    end)

    request = %Request{
      request_id: "test_sync_list_req_#{unique}",
      request_type: "test_sync_list_#{unique}",
      service: "test_service_#{unique}",
      user_id: "user_123",
      device_id: "device_456",
      args: %{"list" => ["Charlie", "David"]}
    }

    result = Executor.execute!(request)

    assert result.request_id == "test_sync_list_req_#{unique}"
    assert result.async == false
    assert result.success == true
    assert result.result == 2
  end

  # Helper test functions
  def test_sync_function(name, age) do
    {:ok, "Hello #{name}, age #{age}"}
  end

  def test_sync_with_info(name, request_info) do
    "Hello #{name}, user: #{request_info.user_id}"
  end

  def test_error_function do
    {:error, "Something went wrong"}
  end

  # Helper test functions
  def test_length_list(list) do
    length(list)
  end
end
