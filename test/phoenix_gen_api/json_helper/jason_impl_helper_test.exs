defmodule PhoenixGenApi.JasonImplHelperTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.Response

  describe "JasonImplHelper macro usage" do
    test "Response struct has Jason.Encoder implementation" do
      response = Response.sync_response("req_123", %{data: "test"})

      # Test that Jason.encode works with Response
      {:ok, json} = Jason.encode(response)

      assert is_binary(json)
      assert json =~ "req_123"
      assert json =~ "data"
    end

    test "handles Response in nested structures" do
      response = Response.async_response("req_456")
      container = %{response: response, status: "ok"}

      {:ok, json} = Jason.encode(container)

      assert is_binary(json)
      assert json =~ "req_456"
      assert json =~ "ok"
    end

    test "encodes Response error correctly" do
      response = Response.error_response("req_err", "Test error")

      {:ok, json} = Jason.encode(response)

      assert is_binary(json)
      assert json =~ "req_err"
      assert json =~ "Test error"
      # success: false
      assert json =~ "false"
    end
  end
end
