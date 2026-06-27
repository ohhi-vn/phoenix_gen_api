defmodule PhoenixGenApi.Structs.FunConfigExtraTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.{FunConfig, Request}
  alias PhoenixGenApi.ArgumentHandler

  describe "local_service?/1" do
    test "returns true when nodes is :local" do
      config = %FunConfig{nodes: :local}
      assert FunConfig.local_service?(config) == true
    end

    test "returns false when nodes is a list" do
      config = %FunConfig{nodes: [:node1@host, :node2@host]}
      assert FunConfig.local_service?(config) == false
    end

    test "returns false when nodes is a single string" do
      config = %FunConfig{nodes: ["node1@host"]}
      assert FunConfig.local_service?(config) == false
    end

    test "returns false when nodes is an MFA tuple" do
      config = %FunConfig{nodes: {__MODULE__, :get_nodes, []}}
      assert FunConfig.local_service?(config) == false
    end
  end

  describe "convert_args!/2 delegation" do
    test "delegates to ArgumentHandler.convert_args!/2" do
      config = %FunConfig{
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"]
      }

      request = %Request{args: %{"name" => "Alice", "age" => 30}}
      assert FunConfig.convert_args!(config, request) == ["Alice", 30]
    end

    test "returns empty list when no args" do
      config = %FunConfig{arg_types: nil, arg_orders: []}
      request = %Request{args: %{}}
      assert FunConfig.convert_args!(config, request) == []
    end

    test "handles nil arg_types" do
      config = %FunConfig{arg_types: nil, arg_orders: nil}
      request = %Request{args: %{}}
      assert FunConfig.convert_args!(config, request) == []
    end
  end

  describe "check_permission!/2" do
    test "delegates to Permission.check_permission! (false)" do
      config = %FunConfig{check_permission: false}
      request = %Request{user_id: "user_123"}
      assert FunConfig.check_permission!(request, config) == nil
    end

    test "delegates to Permission.check_permission! with :any_authenticated" do
      config = %FunConfig{check_permission: :any_authenticated}
      request = %Request{user_id: "user_123"}
      assert FunConfig.check_permission!(request, config) == nil
    end

    test "delegates to Permission.check_permission! with {:arg, arg_name}" do
      config = %FunConfig{check_permission: {:arg, "user_id"}}
      request = %Request{user_id: "user_123", args: %{"user_id" => "user_123"}}
      assert FunConfig.check_permission!(request, config) == nil
    end

    test "delegates to Permission.check_permission! with {:role, roles}" do
      config = %FunConfig{check_permission: {:role, ["admin", "user"]}}
      request = %Request{user_id: "user_123", user_roles: ["user"]}
      assert FunConfig.check_permission!(request, config) == nil
    end
  end

  # Helper functions for permission_callback tests
  def allow_callback(_request), do: true
  def deny_callback(_request), do: false

  def get_nodes do
    [:node1@localhost, :node2@localhost]
  end
end
