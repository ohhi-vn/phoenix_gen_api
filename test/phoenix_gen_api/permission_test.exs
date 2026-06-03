defmodule PhoenixGenApi.PermissionTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.Permission
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  # Test module for permission_callback callbacks
  defmodule TestCallback do
    def allow(_request), do: true
    def deny(_request), do: false
    def unexpected(_request), do: :ok
    def raise_error(_request), do: raise("callback error")
    def throw_value(_request), do: throw(:thrown)
    def allow_with_args(_request, extra), do: extra == "yes"
  end

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

  # ──────────────────────────────────────────────
  # Disabled permissions (check_permission: false)
  # ──────────────────────────────────────────────

  describe "check_permission/2 — disabled (false)" do
    test "returns true regardless of user_id", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: false,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns true even with nil user_id" do
      request = %Request{user_id: nil, args: %{}}
      config = %FunConfig{check_permission: false, version: "0.0.1"}
      assert Permission.check_permission(request, config) == true
    end

    test "returns true even with empty args" do
      request = %Request{user_id: "user_123", args: %{}}
      config = %FunConfig{check_permission: false, version: "0.0.1"}
      assert Permission.check_permission(request, config) == true
    end
  end

  # ──────────────────────────────────────────────
  # :any_authenticated
  # ──────────────────────────────────────────────

  describe "check_permission/2 — :any_authenticated" do
    test "returns true for non-empty binary user_id", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: :any_authenticated,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns false when user_id is nil" do
      request = %Request{user_id: nil, args: %{}}
      config = %FunConfig{check_permission: :any_authenticated, version: "0.0.1"}
      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_id is an empty string" do
      request = %Request{user_id: "", args: %{}}
      config = %FunConfig{check_permission: :any_authenticated, version: "0.0.1"}
      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_id is a non-binary value" do
      request = %Request{user_id: 42, args: %{}}
      config = %FunConfig{check_permission: :any_authenticated, version: "0.0.1"}
      assert Permission.check_permission(request, config) == false
    end
  end

  # ──────────────────────────────────────────────
  # {:arg, arg_name} — standard (non-map)
  # ──────────────────────────────────────────────

  describe "check_permission/2 — {:arg, arg_name} standard" do
    test "returns true when user_id matches arg value", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "user_id"},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns false when user_id does not match arg value", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "other_user_id"},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when arg does not exist in request", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "nonexistent_arg"},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when args is an empty map" do
      request = %Request{user_id: "user_123", args: %{}}
      config = %FunConfig{check_permission: {:arg, "user_id"}, version: "0.0.1"}
      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_id is nil" do
      request = %Request{user_id: nil, args: %{"user_id" => "user_123"}}
      config = %FunConfig{check_permission: {:arg, "user_id"}, version: "0.0.1"}
      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_id is an empty string" do
      request = %Request{user_id: "", args: %{"user_id" => "user_123"}}
      config = %FunConfig{check_permission: {:arg, "user_id"}, version: "0.0.1"}
      assert Permission.check_permission(request, config) == false
    end

    test "returns false when arg_name is an atom but args use string keys" do
      request = %Request{user_id: "user_123", args: %{"user_id" => "user_123"}}
      config = %FunConfig{check_permission: {:arg, :user_id}, version: "0.0.1"}
      assert Permission.check_permission(request, config) == false
    end
  end

  # ──────────────────────────────────────────────
  # {:arg, arg_name} — with arg_orders: :map
  # ──────────────────────────────────────────────

  describe "check_permission/2 — {:arg, arg_name} with arg_orders :map" do
    test "returns true when user_id matches top-level arg value", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns false when user_id does not match top-level arg value", %{
      request: request
    } do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "other_user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns true when user_id matches nested arg value in map" do
      request = %Request{
        request_id: "test_request_id",
        request_type: "test_request",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"params" => %{"user_id" => "user_123", "name" => "Bob"}}
      }

      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns false when user_id does not match nested arg value in map" do
      request = %Request{
        request_id: "test_request_id",
        request_type: "test_request",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"params" => %{"user_id" => "user_999", "name" => "Bob"}}
      }

      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when arg does not exist anywhere in map" do
      request = %Request{
        request_id: "test_request_id",
        request_type: "test_request",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"params" => %{"name" => "Bob"}}
      }

      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_id is nil with arg_orders :map" do
      request = %Request{
        request_id: "test_request_id",
        request_type: "test_request",
        user_id: nil,
        device_id: "device_456",
        args: %{"params" => %{"user_id" => "user_123"}}
      }

      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_id is empty string with arg_orders :map" do
      request = %Request{
        user_id: "",
        args: %{"user_id" => "user_123"}
      }

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "prefers top-level arg over nested arg in map" do
      request = %Request{
        request_id: "test_request_id",
        request_type: "test_request",
        user_id: "user_123",
        device_id: "device_456",
        args: %{"user_id" => "user_123", "params" => %{"user_id" => "user_999"}}
      }

      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns false when args is an empty map" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "skips non-map nested values when searching" do
      request = %Request{
        user_id: "user_123",
        args: %{"params" => "string_value", "data" => %{"user_id" => "user_123"}}
      }

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "finds nested value in second map when first map lacks the key" do
      request = %Request{
        user_id: "user_123",
        args: %{
          "first" => %{"name" => "Bob"},
          "second" => %{"user_id" => "user_123"}
        }
      }

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns first nested match even if it mismatches" do
      request = %Request{
        user_id: "user_123",
        args: %{
          "first" => %{"user_id" => "user_999"},
          "second" => %{"user_id" => "user_123"}
        }
      }

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "does not search deeply nested maps (only one level)" do
      request = %Request{
        user_id: "user_123",
        args: %{"outer" => %{"inner" => %{"user_id" => "user_123"}}}
      }

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when arg_name is an atom but args use string keys" do
      request = %Request{
        user_id: "user_123",
        args: %{"params" => %{"user_id" => "user_123"}}
      }

      config = %FunConfig{
        check_permission: {:arg, :user_id},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "handles mixed value types in args (number, string, map)" do
      request = %Request{
        user_id: "user_123",
        args: %{
          "count" => 42,
          "label" => "hello",
          "nested" => %{"user_id" => "user_123"}
        }
      }

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end
  end

  # ──────────────────────────────────────────────
  # {:role, allowed_roles}
  # ──────────────────────────────────────────────

  describe "check_permission/2 — {:role, allowed_roles}" do
    test "returns true when user has a matching role" do
      request = %Request{
        user_id: "user_123",
        user_roles: ["admin", "editor"]
      }

      config = %FunConfig{
        check_permission: {:role, ["admin", "moderator"]},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns true when user has exactly one matching role" do
      request = %Request{
        user_id: "user_123",
        user_roles: ["editor"]
      }

      config = %FunConfig{
        check_permission: {:role, ["admin", "editor"]},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns false when user has no matching roles" do
      request = %Request{
        user_id: "user_123",
        user_roles: ["viewer"]
      }

      config = %FunConfig{
        check_permission: {:role, ["admin", "moderator"]},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_roles is nil" do
      request = %Request{
        user_id: "user_123",
        user_roles: nil
      }

      config = %FunConfig{
        check_permission: {:role, ["admin"]},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_roles is an empty list" do
      request = %Request{
        user_id: "user_123",
        user_roles: []
      }

      config = %FunConfig{
        check_permission: {:role, ["admin"]},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when allowed_roles is an empty list" do
      request = %Request{
        user_id: "user_123",
        user_roles: ["admin"]
      }

      config = %FunConfig{
        check_permission: {:role, []},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_roles contains atoms but allowed_roles are strings" do
      request = %Request{
        user_id: "user_123",
        user_roles: [:admin]
      }

      config = %FunConfig{
        check_permission: {:role, ["admin"]},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when user_roles is not a list (single string)" do
      request = %Request{
        user_id: "user_123",
        user_roles: "admin"
      }

      config = %FunConfig{
        check_permission: {:role, ["admin"]},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end
  end

  # ──────────────────────────────────────────────
  # permission_callback (MFA tuple)
  # ──────────────────────────────────────────────

  describe "check_permission/2 — permission_callback" do
    test "returns true when callback returns true" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        permission_callback: {TestCallback, :allow, []},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "returns false when callback returns false" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        permission_callback: {TestCallback, :deny, []},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when callback returns non-boolean (atom)" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        permission_callback: {TestCallback, :unexpected, []},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when callback raises an exception" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        permission_callback: {TestCallback, :raise_error, []},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false when callback throws a value" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        permission_callback: {TestCallback, :throw_value, []},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "passes extra args to callback" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        permission_callback: {TestCallback, :allow_with_args, ["yes"]},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "passes extra args to callback — deny case" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        permission_callback: {TestCallback, :allow_with_args, ["no"]},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "callback takes precedence over check_permission" do
      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_999"}
      }

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        permission_callback: {TestCallback, :allow, []},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end
  end

  # ──────────────────────────────────────────────
  # Invalid permission_callback format (fallback)
  # ──────────────────────────────────────────────

  describe "check_permission/2 — invalid permission_callback format" do
    test "falls back to check_permission mode with 2-tuple callback" do
      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_123"}
      }

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        permission_callback: {TestCallback, :allow},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "falls back to check_permission mode with invalid callback and mismatched arg" do
      request = %Request{
        user_id: "user_123",
        args: %{"user_id" => "user_999"}
      }

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        permission_callback: :invalid,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "falls back to :any_authenticated with invalid callback" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        check_permission: :any_authenticated,
        permission_callback: "not_a_tuple",
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end

    test "falls back to false with invalid callback" do
      request = %Request{user_id: nil, args: %{}}

      config = %FunConfig{
        check_permission: false,
        permission_callback: {1, 2, 3},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == true
    end
  end

  # ──────────────────────────────────────────────
  # Invalid check_permission modes
  # ──────────────────────────────────────────────

  describe "check_permission/2 — invalid check_permission mode" do
    test "returns false for unrecognized atom mode" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        check_permission: :invalid_mode,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false for string mode" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        check_permission: "false",
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false for incomplete tuple {:arg}" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        check_permission: {:arg},
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end

    test "returns false for nil check_permission" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        check_permission: nil,
        version: "0.0.1"
      }

      assert Permission.check_permission(request, config) == false
    end
  end

  # ──────────────────────────────────────────────
  # check_permission!/2 — raising version
  # ──────────────────────────────────────────────

  describe "check_permission!/2" do
    test "succeeds (returns nil) when permission check passes", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: false,
        version: "0.0.1"
      }

      assert Permission.check_permission!(request, config) == nil
    end

    test "raises when user_id does not match arg value", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "other_user_id"},
        version: "0.0.1"
      }

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when arg does not exist in request", %{request: request} do
      config = %FunConfig{
        request_type: "test",
        check_permission: {:arg, "nonexistent_arg"},
        version: "0.0.1"
      }

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when :any_authenticated and user_id is nil" do
      request = %Request{user_id: nil, args: %{}}
      config = %FunConfig{check_permission: :any_authenticated, version: "0.0.1"}

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when :any_authenticated and user_id is empty string" do
      request = %Request{user_id: "", args: %{}}
      config = %FunConfig{check_permission: :any_authenticated, version: "0.0.1"}

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when {:role, ...} and no matching roles" do
      request = %Request{user_id: "user_123", user_roles: ["viewer"]}
      config = %FunConfig{check_permission: {:role, ["admin"]}, version: "0.0.1"}

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when {:role, ...} and user_roles is nil" do
      request = %Request{user_id: "user_123", user_roles: nil}
      config = %FunConfig{check_permission: {:role, ["admin"]}, version: "0.0.1"}

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when permission_callback returns false" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        permission_callback: {TestCallback, :deny, []},
        version: "0.0.1"
      }

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when permission_callback raises exception" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        permission_callback: {TestCallback, :raise_error, []},
        version: "0.0.1"
      }

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises for invalid check_permission mode" do
      request = %Request{user_id: "user_123", args: %{}}

      config = %FunConfig{
        check_permission: :unknown,
        version: "0.0.1"
      }

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when {:arg, ...} with nil user_id" do
      request = %Request{user_id: nil, args: %{"user_id" => "user_123"}}
      config = %FunConfig{check_permission: {:arg, "user_id"}, version: "0.0.1"}

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "raises when {:arg, ...} with arg_orders :map and nil user_id" do
      request = %Request{user_id: nil, args: %{"user_id" => "user_123"}}

      config = %FunConfig{
        check_permission: {:arg, "user_id"},
        arg_orders: :map,
        version: "0.0.1"
      }

      assert_raise PhoenixGenApi.Permission.PermissionDenied, ~r/Permission denied/, fn ->
        Permission.check_permission!(request, config)
      end
    end
  end

  # ──────────────────────────────────────────────
  # PermissionDenied exception struct fields
  # ──────────────────────────────────────────────

  describe "PermissionDenied exception fields" do
    test "contains correct user_id, request_id, request_type, permission_mode" do
      request = %Request{
        request_id: "req_abc",
        request_type: "my_api",
        user_id: "user_123",
        args: %{"user_id" => "user_999"}
      }

      config = %FunConfig{
        request_type: "my_api",
        check_permission: {:arg, "user_id"},
        version: "0.0.1"
      }

      assert_raise PhoenixGenApi.Permission.PermissionDenied, fn ->
        Permission.check_permission!(request, config)
      end
    end

    test "permission_mode is {:arg, arg_name} for arg-based checks" do
      request = %Request{
        request_id: "req_1",
        request_type: "api",
        user_id: "u1",
        args: %{}
      }

      config = %FunConfig{
        request_type: "api",
        check_permission: {:arg, "owner_id"},
        version: "0.0.1"
      }

      exception =
        assert_raise PhoenixGenApi.Permission.PermissionDenied, fn ->
          Permission.check_permission!(request, config)
        end

      assert exception.user_id == "u1"
      assert exception.request_id == "req_1"
      assert exception.request_type == "api"
      assert exception.permission_mode == {:arg, "owner_id"}
    end

    test "permission_mode is {:callback, {mod, fun, args}} for callback-based checks" do
      request = %Request{
        request_id: "req_2",
        request_type: "api",
        user_id: "u1",
        args: %{}
      }

      config = %FunConfig{
        request_type: "api",
        check_permission: {:arg, "user_id"},
        permission_callback: {TestCallback, :deny, []},
        version: "0.0.1"
      }

      exception =
        assert_raise PhoenixGenApi.Permission.PermissionDenied, fn ->
          Permission.check_permission!(request, config)
        end

      assert exception.user_id == "u1"
      assert exception.request_id == "req_2"
      assert exception.request_type == "api"
      assert exception.permission_mode == {:callback, {TestCallback, :deny, []}}
    end

    test "permission_mode is :any_authenticated for any_authenticated checks" do
      request = %Request{
        request_id: "req_3",
        request_type: "api",
        user_id: nil,
        args: %{}
      }

      config = %FunConfig{
        request_type: "api",
        check_permission: :any_authenticated,
        version: "0.0.1"
      }

      exception =
        assert_raise PhoenixGenApi.Permission.PermissionDenied, fn ->
          Permission.check_permission!(request, config)
        end

      assert exception.user_id == nil
      assert exception.request_id == "req_3"
      assert exception.permission_mode == :any_authenticated
    end

    test "permission_mode is {:role, allowed_roles} for role-based checks" do
      request = %Request{
        request_id: "req_4",
        request_type: "api",
        user_id: "u1",
        user_roles: ["viewer"]
      }

      config = %FunConfig{
        request_type: "api",
        check_permission: {:role, ["admin"]},
        version: "0.0.1"
      }

      exception =
        assert_raise PhoenixGenApi.Permission.PermissionDenied, fn ->
          Permission.check_permission!(request, config)
        end

      assert exception.user_id == "u1"
      assert exception.request_id == "req_4"
      assert exception.permission_mode == {:role, ["admin"]}
    end
  end
end
