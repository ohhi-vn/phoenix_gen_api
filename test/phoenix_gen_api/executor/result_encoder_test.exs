defmodule PhoenixGenApi.Executor.ResultEncoderTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.ConfigDb
  alias PhoenixGenApi.Executor
  alias PhoenixGenApi.Structs.{FunConfig, Request, Response}

  defmodule TestStruct do
    defstruct [:value]
  end

  # Test-only codecs. The encoder is invoked as apply(mod, fun, [data | args]).
  # Tests pass `self()` as an extra arg so the codec can report the exact data
  # it received (the encoder runs inside a Task, not the test process).
  defmodule TestCodec do
    def encode(data, test_pid) do
      send(test_pid, {:encoder_called, data})
      {:encoded, data}
    end

    def boom(_data, _test_pid) do
      raise "boom"
    end
  end

  setup do
    unique = System.unique_integer([:positive])

    request = %Request{
      request_id: "test_encoder_req_#{unique}",
      request_type: "test_encoder_#{unique}",
      service: "test_service_#{unique}",
      user_id: "user_123",
      device_id: "device_456",
      args: %{}
    }

    {:ok, request: request, unique: unique}
  end

  defp add_config(request_type, service, mfa, encoder, response_type \\ :sync) do
    config = %FunConfig{
      request_type: request_type,
      service: service,
      nodes: :local,
      choose_node_mode: :random,
      timeout: 5000,
      mfa: mfa,
      arg_types: nil,
      arg_orders: nil,
      response_type: response_type,
      check_permission: false,
      request_info: false,
      result_encoder: encoder
    }

    ConfigDb.add(config)

    on_exit(fn ->
      ConfigDb.delete(service, request_type)
    end)
  end

  # Helper mfa functions

  def ok_struct_function do
    {:ok, %TestStruct{value: 1}}
  end

  def ok_string_function do
    {:ok, "payload"}
  end

  def error_function do
    {:error, "order not found"}
  end

  defp with_env(key, value, fun) do
    original = Application.get_env(:phoenix_gen_api, key)

    Application.put_env(:phoenix_gen_api, key, value)

    try do
      fun.()
    after
      if is_nil(original) do
        Application.delete_env(:phoenix_gen_api, key)
      else
        Application.put_env(:phoenix_gen_api, key, original)
      end
    end
  end

  describe "result_encoder applied to successful results" do
    test "sync response encodes {:ok, struct} through the encoder", %{
      request: request,
      unique: unique
    } do
      request_type = "test_encoder_sync_#{unique}"
      service = "test_service_#{unique}"

      add_config(
        request_type,
        service,
        {__MODULE__, :ok_struct_function, []},
        {TestCodec, :encode, [self()]}
      )

      request = %{request | request_type: request_type, service: service}

      result = Executor.execute!(request)

      # Encoder received only the unwrapped data (the struct), not {:ok, data}
      assert_receive {:encoder_called, %TestStruct{value: 1}}
      # Encoder's return value becomes the response result
      assert %Response{success: true, result: {:encoded, %TestStruct{value: 1}}} = result
    end

    test "encoder failure becomes an error response, process stays alive", %{
      request: request,
      unique: unique
    } do
      request_type = "test_encoder_raise_#{unique}"
      service = "test_service_#{unique}"

      add_config(
        request_type,
        service,
        {__MODULE__, :ok_string_function, []},
        {TestCodec, :boom, [self()]}
      )

      request = %{request | request_type: request_type, service: service}

      with_env(:detail_error, true, fn ->
        result = Executor.execute!(request)

        assert %Response{success: false} = result
        assert result.error =~ "result encoding failed"
        assert Process.alive?(self())
      end)
    end

    test "encoder with undefined function becomes an error response", %{
      request: request,
      unique: unique
    } do
      request_type = "test_encoder_undef_#{unique}"
      service = "test_service_#{unique}"

      add_config(
        request_type,
        service,
        {__MODULE__, :ok_string_function, []},
        {TestCodec, :no_such_function, []}
      )

      request = %{request | request_type: request_type, service: service}

      with_env(:detail_error, true, fn ->
        result = Executor.execute!(request)

        assert %Response{success: false} = result
        assert result.error =~ "result encoding failed"
        assert Process.alive?(self())
      end)
    end

    test "denylisted encoder module is rejected by security check", %{
      request: request,
      unique: unique
    } do
      request_type = "test_encoder_deny_#{unique}"
      service = "test_service_#{unique}"

      add_config(
        request_type,
        service,
        {__MODULE__, :ok_string_function, []},
        {:code, :where_is_file, []}
      )

      request = %{request | request_type: request_type, service: service}

      with_env(:detail_error, true, fn ->
        result = Executor.execute!(request)

        assert %Response{success: false} = result
        assert result.error =~ "mfa not allowed"
        # The denylisted encoder must never have been applied
        refute_receive {:encoder_called, _}
      end)
    end

    test "nil result_encoder passes result through unchanged", %{
      request: request,
      unique: unique
    } do
      request_type = "test_encoder_nil_#{unique}"
      service = "test_service_#{unique}"
      add_config(request_type, service, {__MODULE__, :ok_struct_function, []}, nil)

      request = %{request | request_type: request_type, service: service}

      result = Executor.execute!(request)

      assert %Response{success: true, result: %TestStruct{value: 1}} = result
      refute_receive {:encoder_called, _}
    end
  end

  describe "result_encoder pass-through for non-ok results" do
    test "error result is not encoded and keeps the original reason", %{
      request: request,
      unique: unique
    } do
      request_type = "test_encoder_error_#{unique}"
      service = "test_service_#{unique}"

      add_config(
        request_type,
        service,
        {__MODULE__, :error_function, []},
        {TestCodec, :encode, [self()]}
      )

      request = %{request | request_type: request_type, service: service}

      with_env(:detail_error, true, fn ->
        result = Executor.execute!(request)

        assert %Response{success: false} = result
        assert result.error =~ "order not found"
        refute_receive {:encoder_called, _}
      end)
    end
  end

  describe "result_encoder across response types" do
    test "async response is encoded", %{request: request, unique: unique} do
      request_type = "test_encoder_async_#{unique}"
      service = "test_service_#{unique}"

      add_config(
        request_type,
        service,
        {__MODULE__, :ok_struct_function, []},
        {TestCodec, :encode, [self()]},
        :async
      )

      request = %{request | request_type: request_type, service: service}

      result = Executor.execute!(request)

      assert result.async == true
      assert result.success == true
      assert_receive {:encoder_called, %TestStruct{value: 1}}
      assert_receive {:async_call, %Response{result: {:encoded, %TestStruct{value: 1}}}}
    end

    test "none response type with encoder completes without crashing", %{
      request: request,
      unique: unique
    } do
      request_type = "test_encoder_none_#{unique}"
      service = "test_service_#{unique}"

      add_config(
        request_type,
        service,
        {__MODULE__, :ok_struct_function, []},
        {TestCodec, :encode, [self()]},
        :none
      )

      request = %{request | request_type: request_type, service: service}

      result = Executor.execute!(request)

      assert result == {:ok, :no_response}
      assert Process.alive?(self())
    end
  end
end
