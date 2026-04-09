# Test protocol for ImplHelper tests
defprotocol PhoenixGenApi.ImplHelperTest.TestEncoder do
  @doc "Encodes data with options"
  def encode(data, opts)
end

# Test struct with simple encode!/2
defmodule PhoenixGenApi.ImplHelperTest.SimpleStruct do
  defstruct [:name, :value]

  def encode!(%__MODULE__{} = data, _opts) do
    %{name: data.name, value: data.value}
  end
end

# Test struct that uses opts in encode!/2
defmodule PhoenixGenApi.ImplHelperTest.OptsStruct do
  defstruct [:id, :content]

  def encode!(%__MODULE__{} = data, opts) do
    format = Keyword.get(opts, :format, :default)
    %{id: data.id, content: data.content, format: format}
  end
end

# Struct without encode!/2 — for testing the contract requirement
defmodule PhoenixGenApi.ImplHelperTest.NoEncodeStruct do
  defstruct [:data]
  # Intentionally does not implement encode!/2
end

# Generate implementations using gen_impl macro
require PhoenixGenApi.ImplHelper

PhoenixGenApi.ImplHelper.gen_impl(
  PhoenixGenApi.ImplHelperTest.TestEncoder,
  PhoenixGenApi.ImplHelperTest.SimpleStruct
)

PhoenixGenApi.ImplHelper.gen_impl(
  PhoenixGenApi.ImplHelperTest.TestEncoder,
  PhoenixGenApi.ImplHelperTest.OptsStruct
)

PhoenixGenApi.ImplHelper.gen_impl(
  PhoenixGenApi.ImplHelperTest.TestEncoder,
  PhoenixGenApi.ImplHelperTest.NoEncodeStruct
)

# Test structs for `use` macro with multiple modules
defmodule PhoenixGenApi.ImplHelperTest.UseStruct1 do
  defstruct [:field1]

  def encode!(%__MODULE__{} = data, _opts) do
    %{field1: data.field1}
  end
end

defmodule PhoenixGenApi.ImplHelperTest.UseStruct2 do
  defstruct [:field2]

  def encode!(%__MODULE__{} = data, _opts) do
    %{field2: data.field2}
  end
end

# Module that uses ImplHelper with multiple impl modules
defmodule PhoenixGenApi.ImplHelperTest.UseModule do
  use PhoenixGenApi.ImplHelper,
    encoder: PhoenixGenApi.ImplHelperTest.TestEncoder,
    impl: [
      PhoenixGenApi.ImplHelperTest.UseStruct1,
      PhoenixGenApi.ImplHelperTest.UseStruct2
    ]
end

# Module that uses ImplHelper with empty impl list (should compile without error)
defmodule PhoenixGenApi.ImplHelperTest.EmptyImplModule do
  use PhoenixGenApi.ImplHelper,
    encoder: PhoenixGenApi.ImplHelperTest.TestEncoder,
    impl: []
end

# Struct for single-impl test
defmodule PhoenixGenApi.ImplHelperTest.SingleImplStruct do
  defstruct [:single]

  def encode!(%__MODULE__{} = data, _opts) do
    %{single: data.single}
  end
end

# Module that uses ImplHelper with a single impl module
defmodule PhoenixGenApi.ImplHelperTest.SingleImplModule do
  use PhoenixGenApi.ImplHelper,
    encoder: PhoenixGenApi.ImplHelperTest.TestEncoder,
    impl: [PhoenixGenApi.ImplHelperTest.SingleImplStruct]
end

defmodule PhoenixGenApi.ImplHelperTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.ImplHelperTest.TestEncoder

  alias PhoenixGenApi.ImplHelperTest.{
    SimpleStruct,
    OptsStruct,
    NoEncodeStruct,
    UseStruct1,
    UseStruct2,
    SingleImplStruct
  }

  describe "gen_impl/2" do
    test "generates protocol implementation that delegates to encode!/2" do
      struct = %SimpleStruct{name: "hello", value: 42}
      result = TestEncoder.encode(struct, [])
      assert result == %{name: "hello", value: 42}
    end

    test "generates implementation for different struct types" do
      struct = %OptsStruct{id: "abc", content: "world"}
      result = TestEncoder.encode(struct, [])
      assert result == %{id: "abc", content: "world", format: :default}
    end

    test "forwards opts to encode!/2" do
      struct = %OptsStruct{id: "xyz", content: "test"}
      result = TestEncoder.encode(struct, format: :json)
      assert result == %{id: "xyz", content: "test", format: :json}
    end

    test "encode!/2 receives the struct data correctly" do
      struct = %SimpleStruct{name: "encoded", value: 99}
      result = TestEncoder.encode(struct, [])
      assert result.name == "encoded"
      assert result.value == 99
    end

    test "works with nil struct fields" do
      struct = %SimpleStruct{name: nil, value: nil}
      result = TestEncoder.encode(struct, [])
      assert result == %{name: nil, value: nil}
    end

    test "raises UndefinedFunctionError when struct does not implement encode!/2" do
      struct = %NoEncodeStruct{data: "test"}

      assert_raise UndefinedFunctionError, fn ->
        TestEncoder.encode(struct, [])
      end
    end
  end

  describe "__using__/1" do
    test "generates implementations for multiple modules via use" do
      result1 = TestEncoder.encode(%UseStruct1{field1: "a"}, [])
      assert result1 == %{field1: "a"}

      result2 = TestEncoder.encode(%UseStruct2{field2: "b"}, [])
      assert result2 == %{field2: "b"}
    end

    test "handles empty impl list without error" do
      # The EmptyImplModule was defined at compile time without error
      # Verifying it exists and compiled successfully
      assert Code.ensure_loaded?(PhoenixGenApi.ImplHelperTest.EmptyImplModule)
    end

    test "raises when encoder option is missing" do
      # The raise happens at compile time inside the macro expansion.
      # The macro uses `if encoder == nil, do: raise("missing encoder option")`
      # which produces a RuntimeError.
      assert_raise RuntimeError, "missing encoder option", fn ->
        Code.compile_string("""
        defmodule PhoenixGenApi.ImplHelperTest.MissingEncoderModule do
          use PhoenixGenApi.ImplHelper, impl: [PhoenixGenApi.ImplHelperTest.SimpleStruct]
        end
        """)
      end
    end

    test "generates single implementation when impl list has one module" do
      result = TestEncoder.encode(%SingleImplStruct{single: "only"}, [])
      assert result == %{single: "only"}
    end
  end
end
