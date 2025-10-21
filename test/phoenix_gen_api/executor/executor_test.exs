defmodule PhoenixGenApi.ExecutorTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.Structs.{Request, FunConfig}
  alias PhoenixGenApi.ConfigDb

  # ConfigDb is already started by the application

  setup do
    request = %Request{
      request_id: "test_request_id",
      request_type: "test_sync",
      user_id: "user_123",
      device_id: "device_456",
      args: %{"name" => "Alice", "age" => 30}
    }

    {:ok, request: request}
  end

  describe "execute!/1" do
    test "returns error when function config not found" do
      request = %Request{
        request_id: "test_request_id",
        request_type: "test_no_function",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Alice", "age" => 30}
      }

      result = Executor.execute!(request)

      assert result.success == false
      assert result.error =~ "unsupported function"
    end

    test "executes sync call successfully" do
      config = %FunConfig{
        request_type: "test_sync",
        service: "test_service",
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

      request = %Request{
        request_id: "test_sync_req",
        request_type: "test_sync",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Alice", "age" => 30}
      }

      result = Executor.execute!(request)

      assert result.success == true
      assert result.result == {:ok, "Hello Alice, age 30"}
    end

    test "executes sync call with request_info" do
      config = %FunConfig{
        request_type: "test_sync_with_info",
        service: "test_service",
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

      request = %Request{
        request_id: "test_sync_req_info",
        request_type: "test_sync_with_info",
        service: "test_service",
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
      config = %FunConfig{
        request_type: "test_error",
        service: "test_service",
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

      request = %Request{
        request_id: "test_error_req",
        request_type: "test_error",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{}
      }

      result = Executor.execute!(request)

      assert result.success == false
      assert result.error =~ "Internal Server Error"
    end

    test "executes async call" do
      config = %FunConfig{
        request_type: "test_async",
        service: "test_service",
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

      request = %Request{
        request_id: "test_async_req",
        request_type: "test_async",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"name" => "Charlie", "age" => 25}
      }

      result = Executor.execute!(request)

      assert result.async == true
      assert result.success == true
    end

    test "executes none response type (fire and forget)" do
      config = %FunConfig{
        request_type: "test_none",
        service: "test_service",
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

      request = %Request{
        request_id: "test_none_req",
        request_type: "test_none",
        service: "test_service",
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
      config = %FunConfig{
        request_type: "test_params",
        service: "test_service",
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

      params = %{
        "request_id" => "test_params_req",
        "request_type" => "test_params",
        "service" => "test_service",
        "user_id" => "user_123",
        "device_id" => "device_456",
        "args" => %{"name" => "Eve", "age" => 28}
      }

      result = Executor.execute_params!(params)

      assert result.success == true
      assert result.result == {:ok, "Hello Eve, age 28"}
    end
  end

  test "executes sync call with list string" do
    config = %FunConfig{
      request_type: "test_sync",
      service: "test_service",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :test_length_list, []},
      arg_types: %{"list" => :list_string},
      response_type: :sync,
      check_permission: false,
      request_info: false
    }

    ConfigDb.add(config)

    request = %Request{
      request_id: "test_sync_req",
      request_type: "test_sync",
      service: "test_service",
      user_id: "user_123",
      device_id: "device_456",
      args: %{"list" => ["Charlie", "David"]}
    }

    result = Executor.execute!(request)

    assert result.request_id == "test_sync_req"
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
