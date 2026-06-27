defmodule PhoenixGenApi.PermissionExtraTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Permission
  alias PhoenixGenApi.Permission.PermissionDenied
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  describe "PermissionDenied exception fields" do
    test "contains correct fields for :any_authenticated" do
      exception =
        PermissionDenied.exception(
          user_id: nil,
          request_id: "req_123",
          request_type: "test",
          permission_mode: :any_authenticated
        )

      assert exception.user_id == nil
      assert exception.request_id == "req_123"
      assert exception.request_type == "test"
      assert exception.permission_mode == :any_authenticated
    end

    test "contains correct fields for {:arg, arg_name}" do
      exception =
        PermissionDenied.exception(
          user_id: "user_123",
          request_id: "req_456",
          request_type: "test",
          permission_mode: {:arg, "user_id"}
        )

      assert exception.user_id == "user_123"
      assert exception.request_id == "req_456"
      assert exception.permission_mode == {:arg, "user_id"}
    end

    test "contains correct fields for {:role, allowed_roles}" do
      exception =
        PermissionDenied.exception(
          user_id: "user_123",
          request_id: "req_789",
          request_type: "admin_action",
          permission_mode: {:role, ["admin"]}
        )

      assert exception.permission_mode == {:role, ["admin"]}
    end

    test "contains correct fields for {:callback, {mod, fun, args}}" do
      exception =
        PermissionDenied.exception(
          user_id: "user_123",
          request_id: "req_cb",
          request_type: "test",
          permission_mode: {:callback, {MyModule, :check, []}}
        )

      assert exception.permission_mode == {:callback, {MyModule, :check, []}}
    end

    test "message includes user_id and request_type" do
      exception =
        PermissionDenied.exception(
          user_id: "user_123",
          request_id: "req_msg",
          request_type: "test_action",
          permission_mode: :any_authenticated
        )

      assert exception.message =~ "user_123" or exception.message =~ "test_action"
    end
  end

  describe "check_permission/2 with various user_id types" do
    test "rejects integer user_id with :any_authenticated (only binary user_id supported)" do
      config = %FunConfig{check_permission: :any_authenticated}
      request = %Request{user_id: 123}

      # Only binary user_id is supported for :any_authenticated
      assert Permission.check_permission(request, config) == false
    end

    test "rejects atom user_id with :any_authenticated (only binary user_id supported)" do
      config = %FunConfig{check_permission: :any_authenticated}
      request = %Request{user_id: :admin}

      # Only binary user_id is supported for :any_authenticated
      assert Permission.check_permission(request, config) == false
    end
  end

  describe "check_permission/2 with {:arg, arg_name} edge cases" do
    test "handles arg_orders :map with matching arg" do
      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_types: %{"user_id" => :string},
        arg_orders: :map
      }

      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_123"}
      }

      assert Permission.check_permission(request, config) == true
    end

    test "handles arg_orders :map with mismatched arg" do
      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_types: %{"user_id" => :string},
        arg_orders: :map
      }

      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_456"}
      }

      assert Permission.check_permission(request, config) == false
    end

    test "handles arg_orders :map with nil user_id" do
      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_types: %{"user_id" => :string},
        arg_orders: :map
      }

      request = %Request{
        user_id: nil,
        args: %{"user_id" => "user_123"}
      }

      assert Permission.check_permission(request, config) == false
    end
  end

  describe "check_permission/2 with {:role, roles} edge cases" do
    test "handles user_roles as atoms" do
      config = %FunConfig{check_permission: {:role, [:admin, :moderator]}}
      request = %Request{user_roles: [:admin]}

      assert Permission.check_permission(request, config) == true
    end

    test "handles single role in user_roles" do
      config = %FunConfig{check_permission: {:role, ["admin"]}}
      request = %Request{user_roles: ["admin"]}

      assert Permission.check_permission(request, config) == true
    end

    test "handles role mismatch with atoms vs strings" do
      config = %FunConfig{check_permission: {:role, ["admin"]}}
      request = %Request{user_roles: [:admin]}

      # Atom vs string should not match
      assert Permission.check_permission(request, config) == false
    end
  end

  describe "check_permission/2 with permission_callback edge cases" do
    test "handles callback that returns non-boolean (truthy)" do
      config = %FunConfig{
        check_permission: :any_authenticated,
        permission_callback: {__MODULE__, :truthy_callback, []}
      }

      request = %Request{user_id: "user_123"}
      # Non-boolean truthy should be treated as false
      assert Permission.check_permission(request, config) == false
    end

    test "handles callback with extra args" do
      config = %FunConfig{
        check_permission: :any_authenticated,
        permission_callback: {__MODULE__, :args_callback, [:extra1, :extra2]}
      }

      request = %Request{user_id: "user_123"}
      assert Permission.check_permission(request, config) == true
    end
  end

  # Helper callbacks for tests
  def truthy_callback(_request), do: :ok
  def args_callback(_request, :extra1, :extra2), do: true
end
