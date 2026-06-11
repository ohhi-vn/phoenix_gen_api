defmodule PhoenixGenApi.Structs.RequestTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Errors.DecodeError
  alias PhoenixGenApi.Structs.Request

  describe "decode!/1" do
    test "decodes valid params map" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service",
        "user_id" => "user_456",
        "device_id" => "device_789",
        "args" => %{"key" => "value"}
      }

      request = Request.decode!(params)

      assert request.request_id == "req_123"
      assert request.request_type == "test_request"
      assert request.service == "test_service"
      assert request.user_id == "user_456"
      assert request.device_id == "device_789"
      assert request.args == %{"key" => "value"}
    end

    test "sets args to empty map when nil" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service",
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
        "service" => "test_service",
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
        service: "test_service",
        user_id: "user_456",
        device_id: "device_789",
        args: %{key: "value"}
      }

      request = Request.decode!(params)

      assert request.request_id == "req_123"
      assert request.request_type == "test_request"
    end

    test "sets version to nil when not provided" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service"
      }

      request = Request.decode!(params)
      assert is_nil(request.version)
    end

    test "preserves version when provided" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service",
        "version" => "1.2.3"
      }

      request = Request.decode!(params)
      assert request.version == "1.2.3"
    end
  end

  describe "decode!/1 structured error codes" do
    test "raises DecodeError with :missing_field when service is missing" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request"
      }

      assert_raise DecodeError, ~r/Missing required fields/, fn ->
        Request.decode!(params)
      end
    end

    test "raises DecodeError with :missing_field when request_type is missing" do
      params = %{
        "request_id" => "req_123",
        "service" => "test_service"
      }

      assert_raise DecodeError, ~r/Missing required fields/, fn ->
        Request.decode!(params)
      end
    end

    test "raises DecodeError with :missing_field when request_id is missing" do
      params = %{
        "request_type" => "test_request",
        "service" => "test_service"
      }

      assert_raise DecodeError, ~r/Missing required fields/, fn ->
        Request.decode!(params)
      end
    end

    test "raises DecodeError with :missing_field when request_type is empty string" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "",
        "service" => "test_service"
      }

      assert_raise DecodeError, ~r/Missing required fields/, fn ->
        Request.decode!(params)
      end
    end

    test "raises DecodeError with :missing_field when service is empty string" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => ""
      }

      assert_raise DecodeError, ~r/Missing required fields/, fn ->
        Request.decode!(params)
      end
    end

    test "raises DecodeError with :invalid_payload when payload exceeds max size" do
      # Create a payload larger than the default 1MB limit
      big_string = String.duplicate("x", 1_100_000)

      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service",
        "data" => big_string
      }

      assert_raise DecodeError, ~r/exceeds maximum size/, fn ->
        Request.decode!(params)
      end
    end

    test "error code is :invalid_payload for oversized payload" do
      big_string = String.duplicate("x", 1_100_000)

      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service",
        "data" => big_string
      }

      try do
        Request.decode!(params)
      rescue
        e in DecodeError ->
          assert e.code == :invalid_payload
      end
    end

    test "error code is :missing_field for missing required fields" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request"
      }

      try do
        Request.decode!(params)
      rescue
        e in DecodeError ->
          assert e.code == :missing_field
      end
    end

    test "error lists all missing fields in message" do
      params = %{
        "request_id" => "req_123"
      }

      try do
        Request.decode!(params)
      rescue
        e in DecodeError ->
          assert e.message =~ "request_type"
          assert e.message =~ "service"
      end
    end
  end

  describe "max_payload_bytes/0" do
    test "returns default value" do
      assert Request.max_payload_bytes() == 1_000_000
    end
  end
end
