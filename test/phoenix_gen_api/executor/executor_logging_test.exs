defmodule PhoenixGenApi.ExecutorLoggingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  def always_fail(_counter), do: {:error, :boom}

  def stream_init, do: {:ok, :init}

  defp capture_debug(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  defp unique, do: System.unique_integer([:positive])

  defp request(unique, overrides \\ %{}) do
    struct(
      %Request{
        request_id: "log_req_#{unique}",
        request_type: "log_type_#{unique}",
        service: "log_service_#{unique}",
        user_id: "log_user",
        device_id: "log_device",
        args: %{}
      },
      overrides
    )
  end

  defp add_config(config) do
    :ok = ConfigDb.add(config)

    on_exit(fn ->
      ConfigDb.delete(config.service, config.request_type)
    end)
  end

  test "unsupported function logs the full request identity" do
    unique = unique()
    request = request(unique)

    log = capture_log(fn -> assert %{success: false} = Executor.execute!(request) end)

    assert log =~ "[Executor] event=unsupported_function"
    assert log =~ "request_id=\"log_req_#{unique}\""
    assert log =~ "request_type=\"log_type_#{unique}\""
    assert log =~ "service=\"log_service_#{unique}\""
    assert log =~ "user_id=\"log_user\""
    assert log =~ "node=#{inspect(node())}"
  end

  test "remote RPC failure names the failed node and request identity" do
    unique = unique()
    missing_node = :"missing_#{unique}@nowhere"

    config = %FunConfig{
      request_type: "log_type_#{unique}",
      service: "log_service_#{unique}",
      nodes: [missing_node],
      choose_node_mode: :random,
      timeout: 1_000,
      mfa: {__MODULE__, :always_fail, [0]},
      arg_types: nil,
      arg_orders: [],
      response_type: :sync,
      check_permission: false,
      request_info: false
    }

    add_config(config)
    request = request(unique)

    log = capture_log(fn -> assert %{success: false} = Executor.execute!(request) end)

    assert log =~ "event=rpc_failed"
    assert log =~ "failed_node=#{inspect(missing_node)}"
    assert log =~ "node=#{inspect(missing_node)}"
    assert log =~ "request_id=\"log_req_#{unique}\""
    assert log =~ "request_type=\"log_type_#{unique}\""
    assert log =~ "service=\"log_service_#{unique}\""
    assert log =~ "event=no_nodes_available"
  end

  test "retry attempts are debug and retry exhaustion stays warning" do
    unique = unique()

    config = %FunConfig{
      request_type: "log_type_#{unique}",
      service: "log_service_#{unique}",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 1_000,
      mfa: {__MODULE__, :always_fail, [0]},
      arg_types: nil,
      arg_orders: [],
      response_type: :sync,
      check_permission: false,
      request_info: false,
      retry: 1
    }

    add_config(config)
    request = request(unique)

    log = capture_debug(fn -> assert %{success: false} = Executor.execute!(request) end)

    assert log =~ "[debug]"
    assert log =~ "event=local_retry"
    assert log =~ "remaining=1"
    assert log =~ "backoff_ms="
    assert log =~ "event=local_retry_exhausted"
    assert log =~ "request_id=\"log_req_#{unique}\""
  end

  test "consecutive requests in one process do not inherit the previous identity" do
    unique = unique()
    first = request(unique, %{request_id: "first_req_#{unique}"})
    second = request(unique, %{request_id: "second_req_#{unique}"})

    log =
      capture_log(fn ->
        Executor.execute!(first)
        assert Logger.metadata()[:request_id] == nil

        Executor.execute!(second)
        assert Logger.metadata()[:request_id] == nil
      end)

    second_lines =
      log
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "second_req_#{unique}"))

    assert second_lines != []
    refute Enum.any?(second_lines, &String.contains?(&1, "first_req_#{unique}"))
  end

  test "stream timeout logs event, request identity, and stream pid" do
    unique = unique()

    config = %FunConfig{
      request_type: "log_type_#{unique}",
      service: "log_service_#{unique}",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 100,
      mfa: {__MODULE__, :stream_init, []},
      arg_types: nil,
      arg_orders: [],
      response_type: :stream,
      check_permission: false,
      request_info: false
    }

    add_config(config)
    request = request(unique)

    log =
      capture_log(fn ->
        assert %{async: true} = Executor.execute!(request)
        Process.sleep(300)
      end)

    assert log =~ "event=stream_timeout"
    assert log =~ "request_id=\"log_req_#{unique}\""
    assert log =~ "request_type=\"log_type_#{unique}\""
    assert log =~ "service=\"log_service_#{unique}\""
    assert log =~ "stream_pid="
    assert log =~ "timeout_ms=100"
  end
end
