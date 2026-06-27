defmodule PhoenixGenApi.HooksExtraTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Hooks
  alias PhoenixGenApi.Structs.{FunConfig, Request}

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

  describe "run_before/3 with hook_timeout configuration" do
    test "uses custom hook_timeout from config" do
      request = test_request()

      config = %FunConfig{
        request_type: "test",
        service: "test_service",
        nodes: :local,
        choose_node_mode: :random,
        timeout: 5000,
        mfa: {__MODULE__, :dummy, []},
        response_type: :sync,
        check_permission: false,
        hook_timeout: 10_000
      }

      assert {:ok, ^request, ^config} =
               Hooks.run_before({__MODULE__, :before_hook_ok, []}, request, config)
    end
  end

  describe "run_before/3 with hook returning modified request" do
    test "returns modified request from before hook" do
      request = test_request()
      config = test_config()

      modified_request = %{request | user_id: "modified_user"}

      assert {:ok, ^modified_request, ^config} =
               Hooks.run_before(
                 {__MODULE__, :before_hook_modify_request, []},
                 request,
                 config
               )
    end
  end

  describe "run_before/3 with hook returning modified fun_config" do
    test "returns modified fun_config from before hook" do
      request = test_request()
      config = test_config()

      modified_config = %{config | timeout: 99_999}

      assert {:ok, ^request, ^modified_config} =
               Hooks.run_before(
                 {__MODULE__, :before_hook_modify_config, []},
                 request,
                 config
               )
    end
  end

  describe "run_after/3 with various return types" do
    test "returns nil from after hook" do
      request = test_request()
      config = test_config()

      result =
        Hooks.run_after(
          {__MODULE__, :after_hook_return_nil, []},
          request,
          config,
          "original"
        )

      assert result == nil
    end

    test "returns false from after hook" do
      request = test_request()
      config = test_config()

      result =
        Hooks.run_after(
          {__MODULE__, :after_hook_return_false, []},
          request,
          config,
          "original"
        )

      assert result == false
    end

    test "returns integer from after hook" do
      request = test_request()
      config = test_config()

      result =
        Hooks.run_after(
          {__MODULE__, :after_hook_return_int, []},
          request,
          config,
          "original"
        )

      assert result == 42
    end

    test "returns list from after hook" do
      request = test_request()
      config = test_config()

      result =
        Hooks.run_after(
          {__MODULE__, :after_hook_return_list, []},
          request,
          config,
          "original"
        )

      assert result == [1, 2, 3]
    end
  end

  describe "run_after/3 preserves original on hook error" do
    test "returns original result when hook exits" do
      request = test_request()
      config = test_config()

      result =
        Hooks.run_after(
          {__MODULE__, :after_hook_exit, []},
          request,
          config,
          "original_value"
        )

      assert result == "original_value"
    end

    test "returns original result when hook throws" do
      request = test_request()
      config = test_config()

      result =
        Hooks.run_after(
          {__MODULE__, :after_hook_throw, []},
          request,
          config,
          %{data: "original"}
        )

      assert result == %{data: "original"}
    end
  end

  # ── Hook MFA implementations for testing ──

  def before_hook_ok(request, fun_config) do
    {:ok, request, fun_config}
  end

  def before_hook_modify_request(request, fun_config) do
    {:ok, %{request | user_id: "modified_user"}, fun_config}
  end

  def before_hook_modify_config(request, fun_config) do
    {:ok, request, %{fun_config | timeout: 99_999}}
  end

  def after_hook_return_nil(_request, _fun_config, _result) do
    nil
  end

  def after_hook_return_false(_request, _fun_config, _result) do
    false
  end

  def after_hook_return_int(_request, _fun_config, _result) do
    42
  end

  def after_hook_return_list(_request, _fun_config, _result) do
    [1, 2, 3]
  end

  def after_hook_exit(_request, _fun_config, _result) do
    exit(:intentional_exit)
  end

  def after_hook_throw(_request, _fun_config, _result) do
    throw(:intentional_throw)
  end
end
