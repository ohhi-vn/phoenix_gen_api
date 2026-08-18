defprotocol PhoenixGenApi.InternalImplTest.JSON.Encoder do
  @doc "Test protocol standing in for a JSON library encoder"
  def encode(data, opts)
end

defmodule PhoenixGenApi.InternalImplTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Structs.Response

  describe "use PhoenixGenApi.InternalImpl" do
    setup do
      Application.put_env(:phoenix, :json_library, PhoenixGenApi.InternalImplTest.JSON)

      on_exit(fn ->
        Application.delete_env(:phoenix, :json_library)
      end)

      :ok
    end

    test "generates an encoder implementation for PhoenixGenApi.Structs.Response" do
      code = """
      defmodule PhoenixGenApi.InternalImplTest.Generated do
        use PhoenixGenApi.InternalImpl
      end
      """

      Code.compile_string(code)

      response = %Response{request_id: "req_1", result: %{ok: true}, success: true}

      encoded = PhoenixGenApi.InternalImplTest.JSON.Encoder.encode(response, [])

      assert encoded == %{
               request_id: "req_1",
               result: %{ok: true},
               success: true,
               error: nil,
               async: false,
               has_more: false,
               can_retry: false
             }
    end

    test "forwards encode opts to Response.encode!/2" do
      code = """
      defmodule PhoenixGenApi.InternalImplTest.GeneratedWithOpts do
        use PhoenixGenApi.InternalImpl
      end
      """

      Code.compile_string(code)

      response = %Response{request_id: "req_2", success: true}

      encoded = PhoenixGenApi.InternalImplTest.JSON.Encoder.encode(response, [])
      assert encoded.request_id == "req_2"
    end

    test "delegates to the json library configured via :phoenix json_library" do
      # A second protocol to prove the compile-time config is honored.
      Application.put_env(:phoenix, :json_library, PhoenixGenApi.InternalImplTest.JSON)

      code = """
      defmodule PhoenixGenApi.InternalImplTest.CustomLibrary do
        use PhoenixGenApi.InternalImpl
      end
      """

      Code.compile_string(code)

      response = %Response{request_id: "req_3", success: true}
      encoded = PhoenixGenApi.InternalImplTest.JSON.Encoder.encode(response, [])
      assert encoded.success == true
    end
  end
end