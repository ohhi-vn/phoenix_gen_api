defmodule PhoenixGenApi.Structs.StreamHelperTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.StreamHelper

  setup do
    stream = %StreamHelper{
      stream_pid: self(),
      request_id: "stream_req_123"
    }

    {:ok, stream: stream}
  end

  describe "send_result/2" do
    test "sends result message to stream_pid", %{stream: stream} do
      StreamHelper.send_result(stream, "data chunk")

      assert_receive {:result, "data chunk"}
    end
  end

  describe "send_last_result/2" do
    test "sends last_result message to stream_pid", %{stream: stream} do
      StreamHelper.send_last_result(stream, "final data")

      assert_receive {:last_result, "final data"}
    end
  end

  describe "send_complete/1" do
    test "sends complete message to stream_pid", %{stream: stream} do
      StreamHelper.send_complete(stream)

      assert_receive :complete
    end
  end

  describe "send_error/2" do
    test "sends error message to stream_pid", %{stream: stream} do
      StreamHelper.send_error(stream, "error message")

      assert_receive {:error, "error message"}
    end
  end
end
