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
      assert {:ok, node} = FunConfig.get_node(config, request)
      assert node in config.nodes
    end
  end

  describe "local_service?/1" do
    test "returns true when nodes is :local" do
      config = %FunConfig{nodes: :local}
      assert FunConfig.local_service?(config) == true
    end

    test "returns false when nodes is a list" do
      config = %FunConfig{nodes: ["node1@localhost"]}
      assert FunConfig.local_service?(config) == false
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

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        FunConfig.check_permission!(request, config)
      end
    end
  end

  describe "valid?/1" do
    test "correct function configuration with minimal args" do
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

    test "correct function configuration with string args" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"user1" => :string},
        arg_orders: ["user1"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "correct function configuration with multiple args" do
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

    test "incorrect function configuration with arg mismatch" do
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

    test "valid with :uuid type in simple format" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"user_id" => :uuid},
        arg_orders: ["user_id"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid with :uuid type in extended format" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"user_id" => [type: :uuid, allow_nil?: true]},
        arg_orders: ["user_id"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid with :list_uuid type in simple format" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"uuid_list" => :list_uuid},
        arg_orders: ["uuid_list"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid with :list_uuid type with max_items" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"uuid_list" => [type: :list_uuid, max_items: 10]},
        arg_orders: ["uuid_list"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid with mixed uuid types" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{
          "user_id" => :uuid,
          "friend_ids" => :list_uuid,
          "name" => :string
        },
        arg_orders: ["user_id", "friend_ids", "name"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid with arg_orders :map" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{
          "user_id" => :uuid,
          "name" => :string
        },
        arg_orders: :map,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid with unsupported type" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"user_id" => :invalid_type},
        arg_orders: ["user_id"],
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end

    test "invalid with arg_types and arg_orders mismatch" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"user1" => :uuid},
        arg_orders: ["user1", "user2"],
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "validate_with_details/1" do
    test "returns {:ok, config} for valid config" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"name" => :string},
        arg_orders: ["name"],
        response_type: :async
      }

      assert {:ok, _} = FunConfig.validate_with_details(fun)
    end

    test "returns {:error, list} with all validation errors" do
      fun = %FunConfig{
        request_type: "",
        service: nil,
        nodes: nil,
        choose_node_mode: :invalid,
        timeout: 50,
        mfa: {Test, :test, []},
        arg_types: %{"name" => :string},
        arg_orders: ["name"],
        response_type: :invalid
      }

      {:error, errors} = FunConfig.validate_with_details(fun)
      assert is_list(errors)
      assert length(errors) > 1
    end

    test "includes argument validation errors" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"name" => :invalid_type},
        arg_orders: ["name"],
        response_type: :async
      }

      {:error, errors} = FunConfig.validate_with_details(fun)
      assert Enum.any?(errors, &(&1 == "argument validation failed"))
    end
  end

  describe "retry validation" do
    test "valid retry with nil" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async,
        retry: nil
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid retry with number" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async,
        retry: 3
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid retry with {:same_node, number}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async,
        retry: {:same_node, 2}
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid retry with {:all_nodes, number}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async,
        retry: {:all_nodes, 5}
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid retry with zero" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async,
        retry: 0
      }

      assert false == FunConfig.valid?(fun)
    end

    test "invalid retry with negative number" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async,
        retry: -1
      }

      assert false == FunConfig.valid?(fun)
    end

    test "invalid retry with wrong tuple format" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async,
        retry: {:other_mode, 3}
      }

      assert false == FunConfig.valid?(fun)
    end

    test "invalid retry with string" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{},
        arg_orders: [],
        response_type: :async,
        retry: "3"
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "normalize_retry/1" do
    test "returns nil for nil" do
      assert FunConfig.normalize_retry(nil) == nil
    end

    test "converts number to {:all_nodes, number}" do
      assert FunConfig.normalize_retry(3) == {:all_nodes, 3}
    end

    test "converts float to {:all_nodes, truncated}" do
      assert FunConfig.normalize_retry(3.7) == {:all_nodes, 3}
    end

    test "returns {:same_node, n} as-is" do
      assert FunConfig.normalize_retry({:same_node, 2}) == {:same_node, 2}
    end

    test "returns {:all_nodes, n} as-is" do
      assert FunConfig.normalize_retry({:all_nodes, 5}) == {:all_nodes, 5}
    end

    test "truncates float in {:same_node, n}" do
      assert FunConfig.normalize_retry({:same_node, 2.9}) == {:same_node, 2}
    end

    test "truncates float in {:all_nodes, n}" do
      assert FunConfig.normalize_retry({:all_nodes, 5.5}) == {:all_nodes, 5}
    end
  end

  describe "version/1" do
    test "returns version when set" do
      config = %FunConfig{version: "1.0.0"}
      assert FunConfig.version(config) == "1.0.0"
    end

    test "returns nil when version is empty string" do
      config = %FunConfig{version: ""}
      assert FunConfig.version(config) == nil
    end

    test "returns nil when version is nil" do
      config = %FunConfig{version: nil}
      assert FunConfig.version(config) == nil
    end

    test "returns nil for old configs without :version key" do
      config =
        struct(FunConfig, %{
          request_type: "test",
          service: "test_service",
          nodes: [Node.self()],
          choose_node_mode: :random,
          timeout: 5000,
          mfa: {String, :upcase, []},
          arg_types: %{},
          arg_orders: [],
          response_type: :sync,
          check_permission: false,
          request_info: false
        })

      config_without_version = Map.delete(config, :version)
      refute Map.has_key?(config_without_version, :version)
      assert FunConfig.version(config_without_version) == nil
    end

    test "returns nil for reserved sentinel version 0.0.0" do
      config = %FunConfig{version: "0.0.0"}
      assert FunConfig.version(config) == nil
    end
  end

  describe "version sentinel 0.0.0" do
    test "valid? rejects explicit 0.0.0 version" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async,
        version: "0.0.0"
      }

      assert FunConfig.valid?(fun) == false
    end

    test "valid? accepts nil version" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async,
        version: nil
      }

      assert FunConfig.valid?(fun) == true
    end

    test "valid? accepts proper semver version" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async,
        version: "1.0.0"
      }

      assert FunConfig.valid?(fun) == true
    end
  end

  describe "hook_timeout validation" do
    test "valid hook_timeout as positive integer" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async,
        hook_timeout: 5000
      }

      assert FunConfig.valid?(fun) == true
    end

    test "valid hook_timeout with custom value" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async,
        hook_timeout: 10_000
      }

      assert FunConfig.valid?(fun) == true
    end

    test "invalid hook_timeout with zero" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async,
        hook_timeout: 0
      }

      assert FunConfig.valid?(fun) == false
    end

    test "invalid hook_timeout with negative value" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async,
        hook_timeout: -1
      }

      assert FunConfig.valid?(fun) == false
    end

    test "invalid hook_timeout with non-integer" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async,
        hook_timeout: "fast"
      }

      assert FunConfig.valid?(fun) == false
    end

    test "default hook_timeout is 5000" do
      fun = %FunConfig{}
      assert fun.hook_timeout == 5000
    end
  end

  describe "response_type validation" do
    test "valid response_type :sync" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :sync
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid response_type :async" do
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

    test "valid response_type :stream" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :stream
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid response_type :none" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :none
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid response_type" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :invalid
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "check_permission validation" do
    test "valid check_permission false" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        check_permission: false,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid check_permission :any_authenticated" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        check_permission: :any_authenticated,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid check_permission {:arg, arg_name}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        check_permission: {:arg, "user_id"},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid check_permission {:role, roles}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        check_permission: {:role, ["admin", "user"]},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid check_permission" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        check_permission: :invalid,
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "nodes validation" do
    test "valid nodes as list" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: ["node1@localhost", "node2@localhost"],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid nodes as :local" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid nodes as MFA tuple" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: {ClusterHelper, :get_nodes, [:chat]},
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid nodes as empty list" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end

    test "invalid nodes as invalid tuple" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: {Invalid, :func},
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "choose_node_mode validation" do
    test "valid choose_node_mode :random" do
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

    test "valid choose_node_mode :hash" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :hash,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid choose_node_mode {:hash, key}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: {:hash, "user_id"},
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid choose_node_mode :round_robin" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :round_robin,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid choose_node_mode {:sticky, key}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: {:sticky, "user_id"},
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid choose_node_mode" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :invalid,
        timeout: 5_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "timeout validation" do
    test "valid timeout as integer" do
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

    test "valid timeout :infinity" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: :infinity,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid timeout too low" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 50,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end

    test "invalid timeout too high" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 500_000,
        mfa: {Test, :test, []},
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "mfa validation" do
    test "valid mfa tuple" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {String, :upcase, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid mfa not a tuple" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: "not_a_tuple",
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end

    test "invalid mfa wrong tuple format" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {String, :upcase},
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "hooks validation" do
    test "valid before_execute as nil" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        before_execute: nil,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid before_execute as {module, function}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        before_execute: {MyModule, :my_func},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid before_execute as {module, function, args}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        before_execute: {MyModule, :my_func, [1, 2, 3]},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid before_execute" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        before_execute: "invalid",
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end

    test "valid after_execute as nil" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        after_execute: nil,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid after_execute as {module, function}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        after_execute: {MyModule, :my_func},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end
  end

  describe "permission_callback validation" do
    test "valid permission_callback as nil" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        permission_callback: nil,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid permission_callback as {module, function, args}" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        permission_callback: {MyModule, :my_func, []},
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid permission_callback" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        permission_callback: "invalid",
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "request_info validation" do
    test "valid request_info true" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        request_info: true,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid request_info false" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        request_info: false,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid request_info" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        request_info: "not_boolean",
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end
  end

  describe "disabled field" do
    test "valid disabled false" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        disabled: false,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid disabled true" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        disabled: true,
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end
  end

  describe "arg_types with extended format" do
    test "valid with allow_nil? option" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"name" => [type: :string, allow_nil?: true]},
        arg_orders: ["name"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid with default_value option" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"name" => [type: :string, default_value: "default"]},
        arg_orders: ["name"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid with max_bytes for string" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"name" => [type: :string, max_bytes: 5000]},
        arg_orders: ["name"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "valid with max_items for list_uuid" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"uuids" => [type: :list_uuid, max_items: 100]},
        arg_orders: ["uuids"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "complex: multiple args with mixed options" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{
          "name" => [type: :string, max_bytes: 5000, allow_nil?: true],
          "age" => [type: :num, default_value: 18],
          "tags" => [type: :list_string, max_items: 10, max_item_bytes: 100],
          "metadata" => [type: :map, max_items: 50],
          "user_id" => [type: :uuid, allow_nil?: false],
          "friend_ids" => [type: :list_uuid, max_items: 100]
        },
        arg_orders: ["name", "age", "tags", "metadata", "user_id", "friend_ids"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "complex: all simple types with extended format" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{
          "str" => [type: :string],
          "num" => [type: :num],
          "bool" => [type: :boolean],
          "list_str" => [type: :list_string],
          "list_num" => [type: :list_num],
          "list_uuid" => [type: :list_uuid],
          "uuid" => [type: :uuid],
          "map" => [type: :map],
          "any" => [type: :any]
        },
        arg_orders: [
          "str",
          "num",
          "bool",
          "list_str",
          "list_num",
          "list_uuid",
          "uuid",
          "map",
          "any"
        ],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "complex: simple format mixed with extended format" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{
          "simple_str" => :string,
          "ext_str" => [type: :string, max_bytes: 1000],
          "simple_uuid" => :uuid,
          "ext_uuid" => [type: :uuid, allow_nil?: true],
          "simple_list" => :list_uuid,
          "ext_list" => [type: :list_uuid, max_items: 50]
        },
        arg_orders: [
          "simple_str",
          "ext_str",
          "simple_uuid",
          "ext_uuid",
          "simple_list",
          "ext_list"
        ],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "edge case: empty string with allow_nil?" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{
          "optional_field" => [type: :string, allow_nil?: true],
          "required_field" => [type: :string, allow_nil?: false]
        },
        arg_orders: ["optional_field", "required_field"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "edge case: zero max_items" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"items" => [type: :list_uuid, max_items: 0]},
        arg_orders: ["items"],
        response_type: :async
      }

      assert true == FunConfig.valid?(fun)
    end

    test "invalid: default_value type mismatch" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"count" => [type: :num, default_value: "not_a_number"]},
        arg_orders: ["count"],
        response_type: :async
      }

      # Note: Config validation doesn't check if default_value matches type
      # This would fail at runtime, not at config validation time
      assert true == FunConfig.valid?(fun)
    end

    test "invalid: missing type in extended format" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"name" => [max_bytes: 5000]},
        arg_orders: ["name"],
        response_type: :async
      }

      assert false == FunConfig.valid?(fun)
    end

    test "invalid: unknown option in extended format" do
      fun = %FunConfig{
        request_type: "test",
        service: "chat",
        nodes: [Node.self()],
        choose_node_mode: :random,
        timeout: 5_000,
        mfa: {Test, :test, []},
        arg_types: %{"name" => [type: :string, unknown_option: true]},
        arg_orders: ["name"],
        response_type: :async
      }

      # Unknown options are ignored, so this should be valid
      assert true == FunConfig.valid?(fun)
    end
  end
end
