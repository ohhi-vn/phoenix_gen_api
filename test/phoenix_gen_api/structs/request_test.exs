defmodule PhoenixGenApi.Structs.RequestTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.Request

  describe "decode!/1" do
    test "decodes valid params map" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "user_id" => "user_456",
        "device_id" => "device_789",
        "args" => %{"key" => "value"}
      }

      request = Request.decode!(params)

      assert request.request_id == "req_123"
      assert request.request_type == "test_request"
      assert request.user_id == "user_456"
      assert request.device_id == "device_789"
      assert request.args == %{"key" => "value"}
    end

    test "sets args to empty map when nil" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "user_id" => "user_456",
        "device_id" => "device_789",
        "args" => nil
      }

      request = Request.decode!(params)

      assert request.args == %{}
    end

    test "sets args to empty map when not provided" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "user_id" => "user_456",
        "device_id" => "device_789"
      }

      request = Request.decode!(params)

      assert request.args == %{}
    end

    test "handles atom keys in params" do
      params = %{
        request_id: "req_123",
        request_type: "test_request",
        user_id: "user_456",
        device_id: "device_789",
        args: %{key: "value"}
      }

      request = Request.decode!(params)

      assert request.request_id == "req_123"
      assert request.request_type == "test_request"
    end
  end
end
