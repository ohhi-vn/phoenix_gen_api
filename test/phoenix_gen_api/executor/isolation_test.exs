defmodule PhoenixGenApi.Executor.IsolationTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.Structs.{FunConfig, Request, Response}

  def raise_endpoint, do: raise("endpoint boom")

  def exit_endpoint, do: exit(:endpoint_exit)

  def trap_and_sleep do
    Process.flag(:trap_exit, true)
    Process.sleep(5_000)
  end

  def stream_init, do: {:ok, :init}

  def ok_endpoint, do: {:ok, :done}

  def after_rewrite(_request, _fun_config, response), do: %{response | error: "rewritten"}

  def after_identity(_request, _fun_config, response), do: response

  defp request(overrides \\ []) do
    struct(
      %Request{
        request_id: "isolation_#{System.unique_integer([:positive])}",
        request_type: "isolation",
        service: "isolation_service",
        user_id: "user_1",
        device_id: "device_1",
        args: %{}
      },
      overrides
    )
  end

  defp config(overrides) do
    struct(
      %FunConfig{
        request_type: "isolation",
        service: "isolation_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 2_000,
        mfa: {__MODULE__, :raise_endpoint, []},
        arg_types: nil,
        arg_orders: [],
        response_type: :sync,
        check_permission: false,
        request_info: false,
        retry: nil
      },
      overrides
    )
  end

  test "a raising endpoint becomes an error response and does not kill the caller" do
    result = Executor.execute_with_config!(request(), config(%{}))
    pid = self()

    assert %Response{success: false} = result
    assert result.error != nil
    assert Process.alive?(pid)
  end

  test "an exiting endpoint becomes an error response and does not kill the caller" do
    result =
      Executor.execute_with_config!(
        request(),
        config(%{mfa: {__MODULE__, :exit_endpoint, []}})
      )

    assert %Response{success: false} = result
    assert result.error != nil
    assert Process.alive?(self())
  end

  test "a shutdown-ignoring endpoint is killed at the timeout" do
    started_at = System.monotonic_time(:millisecond)

    result =
      Executor.execute_with_config!(
        request(),
        config(%{timeout: 150, mfa: {__MODULE__, :trap_and_sleep, []}})
      )

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert %Response{success: false} = result
    assert elapsed < 1_500, "expected the timeout to bound execution, took #{elapsed}ms"
  end

  test "a stream timeout delivers a terminal error frame" do
    result =
      Executor.execute_with_config!(
        request(),
        config(%{
          timeout: 150,
          response_type: :stream,
          mfa: {__MODULE__, :stream_init, []}
        })
      )

    assert %Response{success: true, result: :init} = result
    assert_receive {:stream_started, _request_id, pid}, 1_000
    assert is_pid(pid)

    assert_receive {:stream_response, %Response{success: false, error: "Stream timed out"}},
                   2_000
  end

  test "the after_execute hook result is returned to the caller" do
    result =
      Executor.execute_with_config!(
        request(),
        config(%{
          mfa: {__MODULE__, :ok_endpoint, []},
          after_execute: {__MODULE__, :after_rewrite, []}
        })
      )

    assert %Response{error: "rewritten"} = result
  end

  test "an after_execute hook that returns the response unchanged is a success" do
    result =
      Executor.execute_with_config!(
        request(),
        config(%{
          mfa: {__MODULE__, :ok_endpoint, []},
          after_execute: {__MODULE__, :after_identity, []}
        })
      )

    assert %Response{success: true, result: :done} = result
  end
end
