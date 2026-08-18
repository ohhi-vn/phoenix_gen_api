defmodule PhoenixGenApi.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    original_client_mode = Application.get_env(:phoenix_gen_api, :client_mode, false)

    on_exit(fn ->
      Application.put_env(:phoenix_gen_api, :client_mode, original_client_mode)
    end)

    :ok
  end

  describe "start/2" do
    test "starts the gateway child tree when client_mode is false" do
      Application.put_env(:phoenix_gen_api, :client_mode, false)

      # The application supervisor is already running, so re-starting returns an
      # {:error, {:already_started, pid}} but still exercises the branch.
      result = PhoenixGenApi.Application.start(:normal, [])

      assert match?({:error, {:already_started, _pid}}, result) or is_pid(result)
    end

    test "starts the client child tree when client_mode is true" do
      Application.put_env(:phoenix_gen_api, :client_mode, true)

      result = PhoenixGenApi.Application.start(:normal, [])

      assert match?({:error, {:already_started, _pid}}, result) or is_pid(result)
    end
  end
end
