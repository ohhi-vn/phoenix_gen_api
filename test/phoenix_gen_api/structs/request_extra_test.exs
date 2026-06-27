defmodule PhoenixGenApi.Structs.RequestExtraTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Errors.DecodeError
  alias PhoenixGenApi.Structs.Request

  describe "decode!/1 with minimal params" do
    test "decodes with only required fields" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service"
      }

      request = Request.decode!(params)

      assert request.request_id == "req_123"
      assert request.request_type == "test_request"
      assert request.service == "test_service"
      assert request.user_id == nil
      assert request.device_id == nil
      assert request.args == %{}
      assert request.version == nil
    end
  end

  describe "decode!/1 with user fields" do
    test "decodes user_id and device_id" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service",
        "user_id" => "user_456",
        "device_id" => "device_789"
      }

      request = Request.decode!(params)

      assert request.user_id == "user_456"
      assert request.device_id == "device_789"
    end
  end

  describe "decode!/1 with version" do
    test "preserves version when provided" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service",
        "version" => "2.0.0"
      }

      request = Request.decode!(params)
      assert request.version == "2.0.0"
    end

    test "version defaults to nil when not provided" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service"
      }

      request = Request.decode!(params)
      assert request.version == nil
    end
  end

  describe "decode!/1 with args" do
    test "decodes complex args map" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service",
        "args" => %{
          "name" => "Alice",
          "age" => 30,
          "tags" => ["admin", "user"],
          "metadata" => %{role: "admin"}
        }
      }

      request = Request.decode!(params)

      assert request.args["name"] == "Alice"
      assert request.args["age"] == 30
      assert request.args["tags"] == ["admin", "user"]
      assert request.args["metadata"] == %{role: "admin"}
    end

    test "handles empty args map" do
      params = %{
        "request_id" => "req_123",
        "request_type" => "test_request",
        "service" => "test_service",
        "args" => %{}
      }

      request = Request.decode!(params)
      assert request.args == %{}
    end
  end

  describe "decode!/1 with atom keys" do
    test "handles all atom keys" do
      params = %{
        request_id: "req_123",
        request_type: "test_request",
        service: "test_service",
        user_id: "user_456"
      }

      request = Request.decode!(params)

      assert request.request_id == "req_123"
      assert request.user_id == "user_456"
    end
  end

  describe "decode!/1 error cases" do
    test "raises when request_id is empty string" do
      params = %{
        "request_id" => "",
        "request_type" => "test_request",
        "service" => "test_service"
      }

      assert_raise DecodeError, ~r/Missing required fields/, fn ->
        Request.decode!(params)
      end
    end

    test "raises when all required fields missing" do
      params = %{}

      assert_raise DecodeError, ~r/Missing required fields/, fn ->
        Request.decode!(params)
      end
    end

    test "error lists all missing fields" do
      params = %{}

      try do
        Request.decode!(params)
      rescue
        e in DecodeError ->
          assert e.message =~ "request_id"
          assert e.message =~ "request_type"
          assert e.message =~ "service"
      end
    end

    test "error code is :missing_field for empty required fields" do
      params = %{
        "request_id" => "",
        "request_type" => "",
        "service" => ""
      }

      try do
        Request.decode!(params)
      rescue
        e in DecodeError ->
          assert e.code == :missing_field
      end
    end
  end

  describe "max_payload_bytes/0" do
    test "returns default 1MB" do
      assert Request.max_payload_bytes() == 1_000_000
    end
  end
end
