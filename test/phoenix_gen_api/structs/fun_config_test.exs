defmodule PhoenixGenApi.Structs.FunConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.{FunConfig, Request}

  setup do
    request = %Request{
      request_id: "test_req",
      request_type: "test",
      user_id: "user_123",
      device_id: "device_456",
      args: %{"name" => "Alice"}
    }

    config = %FunConfig{
      request_type: "test",
      service: "test_service",
      nodes: ["node1@localhost", "node2@localhost"],
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {String, :upcase, []},
      arg_types: %{"name" => :string},
      arg_orders: ["name"],
      response_type: :sync,
      check_permission: false,
      request_info: false
    }

    {:ok, request: request, config: config}
  end

  describe "get_node/2" do
    test "delegates to NodeSelector", %{config: config, request: request} do
      node = FunConfig.get_node(config, request)
      assert node in config.nodes
    end
  end

  describe "is_local_service?/1" do
    test "returns true when nodes is :local" do
      config = %FunConfig{nodes: :local}
      assert FunConfig.is_local_service?(config) == true
    end

    test "returns false when nodes is a list" do
      config = %FunConfig{nodes: ["node1@localhost"]}
      assert FunConfig.is_local_service?(config) == false
    end
  end

  describe "convert_args!/2" do
    test "delegates to ArgumentHandler", %{config: config, request: request} do
      result = FunConfig.convert_args!(config, request)
      assert result == ["Alice"]
    end
  end

  describe "check_permission!/2" do
    test "succeeds when permission check passes", %{config: config, request: request} do
      # Should not raise
      assert FunConfig.check_permission!(request, config) == nil
    end

    test "raises when permission check fails" do
      config = %FunConfig{
        check_permission: {:arg, "user_id"}
      }

      request = %Request{
        request_id: "test_req",
        request_type: "test",
        service: "test_service",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"user_id" => "different_user"}
      }

      assert_raise RuntimeError, ~r/Permission denied/, fn ->
        FunConfig.check_permission!(request, config)
      end
    end
  end

  describe "valid?/1" do
    test "correct function configuration 1" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "correct function configuration 2" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "correct function configuration 3" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        arg_types: %{
          "user1" => :string
        },
        arg_orders: ["user1"],
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "correct function configuration 4" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        arg_types: %{
          "user1" => :string
        },
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "correct function configuration" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{
          "user1" => :string,
          "user2" => :string
        },
        arg_orders: ["user1", "user2"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "incorrect function configuration" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{
          "user1_id" => :string,
          "user2_id" => :string
        },
        arg_orders: nil,
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end
  end
end
