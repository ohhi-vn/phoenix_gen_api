defmodule PhoenixGenApi.PermissionLoggingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixGenApi.Permission
  alias PhoenixGenApi.Permission.PermissionDenied
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  @request %Request{
    user_id: "user_123",
    request_id: "perm_log_req_1",
    request_type: "get_profile",
    service: "profile_service",
    args: %{"user_id" => "user_999"}
  }

  describe "permission denial logging" do
    test "callback returning false logs user_id, request_id, request_type, service and reason" do
      config = %FunConfig{permission_callback: {__MODULE__, :deny, []}}

      log =
        capture_log(fn ->
          assert Permission.check_permission(@request, config) == false
        end)

      assert log =~ "[Permission] callback check denied"
      assert log =~ "callback {PhoenixGenApi.PermissionLoggingTest, :deny} returned false"
      assert log =~ "user_id: \"user_123\""
      assert log =~ "request_id: \"perm_log_req_1\""
      assert log =~ "request_type: \"get_profile\""
      assert log =~ "service: \"profile_service\""
    end

    test "callback raising logs the exception message" do
      config = %FunConfig{permission_callback: {__MODULE__, :raise_error, []}}

      log =
        capture_log(fn ->
          assert Permission.check_permission(@request, config) == false
        end)

      assert log =~ "[Permission] callback check denied"
      assert log =~ "raised: boom"
      assert log =~ "request_type: \"get_profile\""
      assert log =~ "service: \"profile_service\""
    end

    test "arg mismatch logs the expected vs actual values" do
      config = %FunConfig{check_permission: {:arg, "user_id"}}

      log =
        capture_log(fn ->
          assert Permission.check_permission(@request, config) == false
        end)

      assert log =~ "[Permission] arg check denied"
      assert log =~ "mismatch for \"user_id\""
      assert log =~ "expected: \"user_123\""
      assert log =~ "got: \"user_999\""
      assert log =~ "request_type: \"get_profile\""
      assert log =~ "service: \"profile_service\""
    end

    test "missing arg logs the missing argument name" do
      request = %{@request | args: %{}}
      config = %FunConfig{check_permission: {:arg, "user_id"}}

      log =
        capture_log(fn ->
          assert Permission.check_permission(request, config) == false
        end)

      assert log =~ "[Permission] arg check denied"
      assert log =~ "missing argument \"user_id\""
    end

    test "role check denial logs required and actual roles" do
      request = %{@request | user_roles: ["viewer"]}
      config = %FunConfig{check_permission: {:role, ["admin", "moderator"]}}

      log =
        capture_log(fn ->
          assert Permission.check_permission(request, config) == false
        end)

      assert log =~ "[Permission] role check denied"
      assert log =~ "required: [\"admin\", \"moderator\"]"
      assert log =~ "has: [\"viewer\"]"
    end

    test ":any_authenticated denial with nil user_id logs the user_id" do
      request = %{@request | user_id: nil}
      config = %FunConfig{check_permission: :any_authenticated}

      log =
        capture_log(fn ->
          assert Permission.check_permission(request, config) == false
        end)

      assert log =~ "[Permission] :any_authenticated denied"
      assert log =~ "user_id is nil"
      assert log =~ "request_type: \"get_profile\""
    end

    test "arg check with nil/empty user_id logs a warning with request context" do
      request = %{@request | user_id: nil}
      config = %FunConfig{check_permission: {:arg, "user_id"}}

      log =
        capture_log(fn ->
          assert Permission.check_permission(request, config) == false
        end)

      assert log =~ "{:arg, \"user_id\"} check with nil/empty user_id"
      assert log =~ "require_verified_user_id: true"
      assert log =~ "request_type: \"get_profile\""
      assert log =~ "service: \"profile_service\""
    end
  end

  describe "check_permission!/2 logging" do
    test "denial logs user_id, request_id, request_type, service and mode" do
      config = %FunConfig{check_permission: {:arg, "user_id"}}

      log =
        capture_log(fn ->
          assert_raise PermissionDenied, fn ->
            Permission.check_permission!(@request, config)
          end
        end)

      assert log =~ "[Permission] denied"
      assert log =~ "user_id: \"user_123\""
      assert log =~ "request_id: \"perm_log_req_1\""
      assert log =~ "request_type: \"get_profile\""
      assert log =~ "service: \"profile_service\""
      assert log =~ "mode: {:arg, \"user_id\"}"
    end

    test "callback denial logs the callback permission mode" do
      config = %FunConfig{permission_callback: {__MODULE__, :deny, []}}

      log =
        capture_log(fn ->
          assert_raise PermissionDenied, fn ->
            Permission.check_permission!(@request, config)
          end
        end)

      assert log =~ "mode: {:callback, {PhoenixGenApi.PermissionLoggingTest, :deny, []}}"
    end

    test "success does not log a warning" do
      request = %{@request | user_id: "user_123", args: %{"user_id" => "user_123"}}
      config = %FunConfig{check_permission: {:arg, "user_id"}}

      log = capture_log(fn -> Permission.check_permission!(request, config) end)
      assert log == ""
    end
  end

  def deny(_request), do: false

  def raise_error(_request), do: raise("boom")
end
