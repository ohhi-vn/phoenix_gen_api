defmodule PhoenixGenApi.ArgumentHandlerTest do
  use ExUnit.Case

  alias PhoenixGenApi.ArgumentHandler
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  describe "convert_args!/2" do
    test "converts arguments for a function with no arguments" do
      config = %FunConfig{arg_types: %{}, arg_orders: []}
      request = %Request{args: %{}}
      assert ArgumentHandler.convert_args!(config, request) == []
    end

    test "converts arguments for a function with one argument" do
      config = %FunConfig{arg_types: %{"name" => :string}, arg_orders: ["name"]}
      request = %Request{args: %{"name" => "John"}}
      assert ArgumentHandler.convert_args!(config, request) == ["John"]
    end

    test "converts arguments for a function with multiple arguments" do
      config = %FunConfig{
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"]
      }

      request = %Request{args: %{"name" => "John", "age" => 30}}
      assert ArgumentHandler.convert_args!(config, request) == ["John", 30]
    end

    test "raises an error for missing arguments" do
      config = %FunConfig{
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"]
      }

      request = %Request{args: %{"name" => "John"}}

      assert_raise RuntimeError, "invalid number of arguments for nil", fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end
  end

  describe "validate_args!/2" do
    test "validates a request with no arguments" do
      config = %FunConfig{arg_types: nil}
      request = %Request{args: %{}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "validates a request with correct arguments" do
      config = %FunConfig{arg_types: %{"name" => :string, "age" => :num}}
      request = %Request{args: %{"name" => "John", "age" => 30}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "raises an error for an invalid number of arguments" do
      config = %FunConfig{arg_types: %{"name" => :string, "age" => :num}}
      request = %Request{args: %{"name" => "John"}}

      assert_raise RuntimeError, "invalid number of arguments for nil", fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "raises an error for invalid arguments" do
      config = %FunConfig{arg_types: %{"name" => :string, "age" => :num}}
      request = %Request{args: %{"name" => "John", "city" => "New York"}}

      assert_raise RuntimeError, "invalid arguments for nil", fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "validates a list argument with a size limit" do
      config = %FunConfig{arg_types: %{"list" => {:list, 10}}}
      request = %Request{args: %{"list" => [1, 2, 3]}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "raises an error for a list argument exceeding the size limit" do
      config = %FunConfig{arg_types: %{"list" => {:list, 2}}}
      request = %Request{args: %{"list" => [1, 2, 3]}}

      assert_raise RuntimeError, "invalid argument size for \"list\" in nil", fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "validates a map argument with a size limit" do
      config = %FunConfig{arg_types: %{"map" => {:map, 10}}}
      request = %Request{args: %{"map" => %{"a" => 1, "b" => 2}}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "raises an error for a map argument exceeding the size limit" do
      config = %FunConfig{arg_types: %{"map" => {:map, 1}}}
      request = %Request{args: %{"map" => %{"a" => 1, "b" => 2}}}

      assert_raise RuntimeError, "invalid argument size for \"map\" in nil", fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end
  end
end
