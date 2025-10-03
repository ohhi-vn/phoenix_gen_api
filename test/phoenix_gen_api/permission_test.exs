defmodule PhoenixGenApi.PermissionTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Permission
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  setup do
    request = %Request{
      request_id: "test_request_id",
      request_type: "test_request",
      user_id: "user_123",
      device_id: "device_456",
      args: %{"user_id" => "user_123", "other_user_id" => "user_999"}
    }

    {:ok, request: request}
  end

  describe "check_permission/2" do
    test "returns true when check_permission is false", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: false
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns true when user_id matches arg value", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "user_id"}
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns false when user_id does not match arg value", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "other_user_id"}
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when arg does not exist in request", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "nonexistent_arg"}
      }

      assert Permission.check_permission(request, config) == false
    end
  end

  describe "check_permission!/2" do
    test "succeeds when permission check passes", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: false
      }

      assert Permission.check_permission!(request, config) == nil
    end

    test "raises when user_id does not match arg value", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "other_user_id"}
      }

      assert_raise RuntimeError, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when arg does not exist in request", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "nonexistent_arg"}
      }

      assert_raise RuntimeError, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end
  end
end
