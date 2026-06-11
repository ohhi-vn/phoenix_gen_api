defmodule PhoenixGenApi.HooksTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.{FunConfig, Request}
  alias PhoenixGenApi.Hooks

  defp test_request do
    %Request{
      request_id: "test_req",
      request_type: "test",
      service: "test_service",
      user_id: "user_123",
      args: %{}
    }
  end

  defp test_config do
    %FunConfig{
      request_type: "test",
      service: "test_service",
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: {__MODULE__, :dummy, []},
      response_type: :sync,
      check_permission: false
    }
  end

  def dummy, do: :ok

  describe "run_before/3" do
    test "returns {:ok, request, fun_config} when hook is nil" do
      request = test_request()
      config = test_config()

      assert {:ok, ^request, ^config} = Hooks.run_before(nil, request, config)
    end

    test "calls before hook with {mod, fun} tuple" do
      request = test_request()
      config = test_config()

      assert {:ok, ^request, ^config} =
               Hooks.run_before({__MODULE__, :before_hook_ok, []}, request, config)
    end

    test "calls before hook with {mod, fun, extra_args} tuple" do
      request = test_request()
      config = test_config()

      assert {:ok, ^request, ^config} =
               Hooks.run_before({__MODULE__, :before_hook_with_args, ["extra"]}, request, config)
    end

    test "returns {:error, reason} when before hook returns {:error, reason}" do
      request = test_request()
      config = test_config()

      assert {:error, "hook rejected"} =
               Hooks.run_before({__MODULE__, :before_hook_reject, []}, request, config)
    end

    test "returns {:ok, request, fun_config} when before hook returns unexpected value" do
      request = test_request()
      config = test_config()

      assert {:ok, ^request, ^config} =
               Hooks.run_before({__MODULE__, :before_hook_unexpected, []}, request, config)
    end

    test "returns {:error, reason} when before hook raises exception" do
      request = test_request()
      config = test_config()

      assert {:error, msg} =
               Hooks.run_before({__MODULE__, :before_hook_raise, []}, request, config)

      assert msg =~ "intentional error"
    end

    test "returns {:error, reason} when before hook times out" do
      request = test_request()
      config = test_config()

      assert {:error, msg} =
               Hooks.run_before({__MODULE__, :before_hook_slow, []}, request, config)

      assert msg =~ "hook timed out"
    end
  end

  describe "run_after/4" do
    test "returns result when hook is nil" do
      request = test_request()
      config = test_config()

      assert Hooks.run_after(nil, request, config, "my_result") == "my_result"
    end

    test "calls after hook with {mod, fun} tuple" do
      request = test_request()
      config = test_config()

      assert Hooks.run_after({__MODULE__, :after_hook_ok, []}, request, config, "result") ==
               "modified_result"
    end

    test "calls after hook with {mod, fun, extra_args} tuple" do
      request = test_request()
      config = test_config()

      assert Hooks.run_after(
               {__MODULE__, :after_hook_with_args, ["extra"]},
               request,
               config,
               "result"
             ) == "modified_with_extra"
    end

    test "returns hook result when after hook returns a value" do
      request = test_request()
      config = test_config()

      # After hook can modify the result to any value, including :unexpected
      assert Hooks.run_after(
               {__MODULE__, :after_hook_unexpected, []},
               request,
               config,
               "original"
             ) == :unexpected
    end

    test "returns original result when after hook crashes" do
      request = test_request()
      config = test_config()

      assert Hooks.run_after(
               {__MODULE__, :after_hook_raise, []},
               request,
               config,
               "original"
             ) == "original"
    end

    test "returns original result when after hook raises exception" do
      request = test_request()
      config = test_config()

      assert Hooks.run_after(
               {__MODULE__, :after_hook_raise, []},
               request,
               config,
               "original"
             ) == "original"
    end

    test "returns original result when after hook times out" do
      request = test_request()
      config = test_config()

      assert Hooks.run_after(
               {__MODULE__, :after_hook_slow, []},
               request,
               config,
               "original"
             ) == "original"
    end
  end

  # ── Hook MFA implementations for testing ──

  def before_hook_ok(request, fun_config) do
    {:ok, request, fun_config}
  end

  def before_hook_with_args(request, fun_config, "extra") do
    {:ok, request, fun_config}
  end

  def before_hook_reject(_request, _fun_config) do
    {:error, "hook rejected"}
  end

  def before_hook_unexpected(_request, _fun_config) do
    :unexpected
  end

  def before_hook_raise(_request, _fun_config) do
    raise "intentional error"
  end

  def before_hook_slow(_request, _fun_config) do
    receive do
      :never -> :ok
    end

    {:ok, nil, nil}
  end

  def after_hook_ok(_request, _fun_config, _result) do
    "modified_result"
  end

  def after_hook_with_args(_request, _fun_config, _result, "extra") do
    "modified_with_extra"
  end

  def after_hook_unexpected(_request, _fun_config, _result) do
    :unexpected
  end

  def after_hook_raise(_request, _fun_config, _result) do
    raise "intentional error"
  end

  def after_hook_slow(_request, _fun_config, _result) do
    receive do
      :never -> :ok
    end

    "never_reached"
  end
end
