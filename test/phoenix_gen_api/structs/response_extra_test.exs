defmodule PhoenixGenApi.Structs.ResponseExtraTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.Response

  describe "async_response/1" do
    test "creates async response with request_id" do
      response = Response.async_response("req_async_1")
      assert response.request_id == "req_async_1"
      assert response.async == true
      assert response.success == true
      assert response.has_more == false
      assert response.result == nil
      assert response.error == nil
    end

    test "creates async response with nil request_id" do
      response = Response.async_response(nil)
      assert response.request_id == nil
      assert response.async == true
    end
  end

  describe "stream_response/3" do
    test "creates stream response with has_more true" do
      response = Response.stream_response("req_stream", "chunk_data")
      assert response.request_id == "req_stream"
      assert response.result == "chunk_data"
      assert response.async == true
      assert response.has_more == true
      assert response.success == true
    end

    test "creates stream response with has_more false" do
      response = Response.stream_response("req_stream", "final_chunk", false)
      assert response.request_id == "req_stream"
      assert response.result == "final_chunk"
      assert response.has_more == false
      assert response.success == true
    end

    test "creates stream response with nil result" do
      response = Response.stream_response("req_stream", nil, false)
      assert response.result == nil
      assert response.has_more == false
    end

    test "creates stream response with map result" do
      data = %{items: [1, 2, 3], count: 3}
      response = Response.stream_response("req_stream", data, true)
      assert response.result == data
      assert response.has_more == true
    end
  end

  describe "stream_end_response/1" do
    test "creates stream end response" do
      response = Response.stream_end_response("req_end")
      assert response.request_id == "req_end"
      assert response.async == true
      assert response.has_more == false
      assert response.success == true
      assert response.result == nil
    end
  end

  describe "sync_response/2" do
    test "creates successful sync response with map result" do
      response = Response.sync_response("req_sync", %{data: "value"})
      assert response.request_id == "req_sync"
      assert response.result == %{data: "value"}
      assert response.success == true
      assert response.async == false
      assert response.has_more == false
      assert response.error == nil
    end

    test "creates sync response with nil result" do
      response = Response.sync_response("req_sync", nil)
      assert response.result == nil
      assert response.success == true
    end

    test "creates sync response with list result" do
      response = Response.sync_response("req_sync", [1, 2, 3])
      assert response.result == [1, 2, 3]
    end
  end

  describe "error_response/2" do
    test "creates error response with string error" do
      response = Response.error_response("req_err", "Something went wrong")
      assert response.request_id == "req_err"
      assert response.error == "Something went wrong"
      assert response.success == false
    end

    test "creates error response with nil error" do
      response = Response.error_response("req_err", nil)
      assert response.error == nil
      assert response.success == false
    end

    test "creates error response with detailed error map" do
      error_info = %{code: "VALIDATION_ERROR", details: "field is required"}
      response = Response.error_response("req_err", error_info)
      assert response.error == error_info
    end
  end

  describe "error?/1" do
    test "returns true for error response" do
      response = Response.error_response("req", "error")
      assert Response.error?(response) == true
    end

    test "returns false for sync success response" do
      response = Response.sync_response("req", "data")
      assert Response.error?(response) == false
    end

    test "returns false for async response" do
      response = Response.async_response("req")
      assert Response.error?(response) == false
    end

    test "returns false for stream response" do
      response = Response.stream_response("req", "data")
      assert Response.error?(response) == false
    end

    test "returns false for stream end response" do
      response = Response.stream_end_response("req")
      assert Response.error?(response) == false
    end
  end

  describe "JSON encoding" do
    test "encodes sync response to valid JSON" do
      response = Response.sync_response("req_123", %{key: "value"})
      json = JSON.encode!(response)
      assert is_binary(json)

      {:ok, parsed} = JSON.decode(json)
      assert parsed["request_id"] == "req_123"
      assert parsed["success"] == true
      assert parsed["async"] == false
    end

    test "encodes error response to valid JSON" do
      response = Response.error_response("req_err", "error message")
      json = JSON.encode!(response)
      assert is_binary(json)

      {:ok, parsed} = JSON.decode(json)
      assert parsed["request_id"] == "req_err"
      assert parsed["success"] == false
      assert parsed["error"] == "error message"
    end

    test "encodes stream response to valid JSON" do
      response = Response.stream_response("req_stream", "chunk", true)
      json = JSON.encode!(response)

      {:ok, parsed} = JSON.decode(json)
      assert parsed["request_id"] == "req_stream"
      assert parsed["result"] == "chunk"
      assert parsed["has_more"] == true
    end

    test "encodes async response to valid JSON" do
      response = Response.async_response("req_async")
      json = JSON.encode!(response)

      {:ok, parsed} = JSON.decode(json)
      assert parsed["request_id"] == "req_async"
      assert parsed["async"] == true
    end
  end

  describe "struct fields" do
    test "response struct has expected fields" do
      response = Response.sync_response("req", "data")

      assert Map.has_key?(response, :request_id)
      assert Map.has_key?(response, :result)
      assert Map.has_key?(response, :success)
      assert Map.has_key?(response, :async)
      assert Map.has_key?(response, :has_more)
      assert Map.has_key?(response, :error)
    end
  end
end
