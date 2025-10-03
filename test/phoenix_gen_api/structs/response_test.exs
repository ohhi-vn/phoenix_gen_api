defmodule PhoenixGenApi.Structs.ResponseTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.Response

  describe "sync_response/2" do
    test "creates successful sync response" do
      response = Response.sync_response("req_123", %{data: "test"})

      assert response.request_id == "req_123"
      assert response.result == %{data: "test"}
      assert response.success == true
      assert response.async == false
      assert response.has_more == false
      assert response.error == nil
    end
  end

  describe "async_response/1" do
    test "creates async acknowledgment response" do
      response = Response.async_response("req_456")

      assert response.request_id == "req_456"
      assert response.async == true
      assert response.success == true
      assert response.has_more == false
    end
  end

  describe "stream_response/3" do
    test "creates stream response with has_more true by default" do
      response = Response.stream_response("req_789", "chunk1")

      assert response.request_id == "req_789"
      assert response.result == "chunk1"
      assert response.async == true
      assert response.has_more == true
      assert response.success == true
    end

    test "creates stream response with has_more false" do
      response = Response.stream_response("req_789", "final_chunk", false)

      assert response.request_id == "req_789"
      assert response.result == "final_chunk"
      assert response.async == true
      assert response.has_more == false
      assert response.success == true
    end
  end

  describe "stream_end_response/1" do
    test "creates stream end response" do
      response = Response.stream_end_response("req_end")

      assert response.request_id == "req_end"
      assert response.async == true
      assert response.has_more == false
      assert response.success == true
    end
  end

  describe "error_response/2" do
    test "creates error response" do
      response = Response.error_response("req_error", "Something went wrong")

      assert response.request_id == "req_error"
      assert response.error == "Something went wrong"
      assert response.success == false
    end
  end

  describe "is_error?/1" do
    test "returns true for error response" do
      response = Response.error_response("req_1", "error")
      assert Response.is_error?(response) == true
    end

    test "returns false for successful response" do
      response = Response.sync_response("req_2", "data")
      assert Response.is_error?(response) == false
    end
  end

  describe "JSON encoding" do
    test "encodes response to JSON via Jason" do
      response = Response.sync_response("req_123", %{data: "test"})

      {:ok, json} = Jason.encode(response)

      assert is_binary(json)
      assert json =~ "req_123"
      assert json =~ "true"
    end
  end
end
