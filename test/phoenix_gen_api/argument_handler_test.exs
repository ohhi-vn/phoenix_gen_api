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

      assert_raise ArgumentError, ~r/missing or nil argument/, fn ->
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

    test "raises an error for invalid arguments" do
      config = %FunConfig{arg_types: %{"name" => :string, "age" => :num}}
      request = %Request{args: %{"name" => "John", "city" => "New York"}}

      assert_raise ArgumentError, ~r/extra arguments for nil, extra:.*city/, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "raises an error for missing arguments with invalid number" do
      config = %FunConfig{arg_types: %{"name" => :string, "age" => :num}}
      request = %Request{args: %{"name" => "John"}}

      assert_raise ArgumentError, ~r/missing or nil argument/, fn ->
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

      assert_raise ArgumentError, ~r/invalid argument size for "list" in nil, max/, fn ->
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

      assert_raise ArgumentError, ~r/invalid argument size for "map" in nil, max/, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "valid max length of :list_num" do
      config = %FunConfig{arg_types: %{"name" => {:list_num, 12}}}
      request = %Request{args: %{"name" => [1, 2, 3, 4]}}

      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "raises an error for an invalid max length of :list_num" do
      config = %FunConfig{arg_types: %{"name" => {:list_num, 2}}}
      request = %Request{args: %{"name" => [1, 2, 3, 4]}}

      assert_raise ArgumentError, ~r/invalid argument size for "name", max/, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end
  end

  describe "extended arg_types format" do
    test "accepts nil when allow_nil? is true" do
      config = %FunConfig{
        arg_types: %{"name" => [type: :string, allow_nil?: true]},
        arg_orders: ["name"]
      }

      request = %Request{args: %{"name" => nil}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects nil when allow_nil? is false" do
      config = %FunConfig{
        arg_types: %{"name" => [type: :string, allow_nil?: false]},
        arg_orders: ["name"]
      }

      request = %Request{args: %{"name" => nil}}

      assert_raise ArgumentError, ~r/missing or nil argument/, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "uses default value when argument is missing" do
      config = %FunConfig{
        arg_types: %{
          "name" => [type: :string],
          "age" => [type: :num, default_value: 25]
        },
        arg_orders: ["name", "age"]
      }

      request = %Request{args: %{"name" => "John"}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == ["John", 25]
    end

    test "uses default value for nil when allow_nil? is true" do
      config = %FunConfig{
        arg_types: %{
          "name" => [type: :string],
          "email" => [type: :string, allow_nil?: true, default_value: nil]
        },
        arg_orders: ["name", "email"]
      }

      request = %Request{args: %{"name" => "John"}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == ["John", nil]
    end

    test "extended format with max_bytes" do
      config = %FunConfig{
        arg_types: %{
          "name" => [type: :string, max_bytes: 255],
          "tags" => [type: :list_string, max_items: 10, max_item_bytes: 100]
        },
        arg_orders: ["name", "tags"]
      }

      request = %Request{args: %{"name" => "John", "tags" => ["a", "b"]}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == ["John", ["a", "b"]]
    end

    test "simple format still works" do
      config = %FunConfig{
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"]
      }

      request = %Request{args: %{"name" => "John", "age" => 30}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == ["John", 30]
    end

    test "validates default_value type matches for string" do
      # Valid: default is a string
      config = %FunConfig{
        arg_types: %{"name" => [type: :string, default_value: "hello"]},
        arg_orders: ["name"]
      }
      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == ["hello"]
    end

    test "invalid default_value type for string is caught in validation" do
      # This should fail because default_value is not a string
      config = %FunConfig{
        arg_types: %{"name" => [type: :string, default_value: 123]},
        arg_orders: ["name"]
      }
      # The config itself should be invalid
      assert {:error, _} = FunConfig.validate_with_details(config)
    end

    test "validates default_value type matches for num" do
      config = %FunConfig{
        arg_types: %{"age" => [type: :num, default_value: 25]},
        arg_orders: ["age"]
      }
      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [25]
    end

    test "validates default_value type matches for boolean" do
      config = %FunConfig{
        arg_types: %{"active" => [type: :boolean, default_value: true]},
        arg_orders: ["active"]
      }
      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [true]
    end

    test "validates default_value type matches for list" do
      config = %FunConfig{
        arg_types: %{"tags" => [type: :list, default_value: [1, 2, 3]]},
        arg_orders: ["tags"]
      }
      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [[1, 2, 3]]
    end

    test "validates default_value type matches for list_string" do
      config = %FunConfig{
        arg_types: %{"tags" => [type: :list_string, default_value: ["a", "b"]]},
        arg_orders: ["tags"]
      }
      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [["a", "b"]]
    end

    test "validates default_value type matches for list_num" do
      config = %FunConfig{
        arg_types: %{"scores" => [type: :list_num, default_value: [1.0, 2.5]]},
        arg_orders: ["scores"]
      }
      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [[1.0, 2.5]]
    end

    test "validates default_value type matches for map" do
      config = %FunConfig{
        arg_types: %{"data" => [type: :map, default_value: %{"key" => "value"}]},
        arg_orders: ["data"]
      }
      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [%{"key" => "value"}]
    end

    test "uses default when argument is missing and allow_nil? is false" do
      config = %FunConfig{
        arg_types: %{
          "name" => [type: :string],
          "email" => [type: :string, default_value: "default@email.com"]
        },
        arg_orders: ["name", "email"]
      }
      request = %Request{args: %{"name" => "John"}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == ["John", "default@email.com"]
    end

    test "nil argument with allow_nil? true overrides default_value" do
      config = %FunConfig{
        arg_types: %{
          "email" => [type: :string, allow_nil?: true, default_value: "default@email.com"]
        },
        arg_orders: ["email"]
      }
      # When nil is explicitly passed and allow_nil? is true, nil is used (not default)
      request = %Request{args: %{"email" => nil}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [nil]
    end

    test "missing argument with allow_nil? true and no default" do
      config = %FunConfig{
        arg_types: %{
          "email" => [type: :string, allow_nil?: true]
        },
        arg_orders: ["email"]
      }
      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [nil]
    end
  end

  describe "uuid type" do
    test "accepts valid UUID" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      config = %FunConfig{arg_types: %{"user_id" => :uuid}}
      request = %Request{args: %{"user_id" => uuid}}

      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects invalid UUID" do
      config = %FunConfig{arg_types: %{"user_id" => :uuid}}
      request = %Request{args: %{"user_id" => "incorrect uuid"}}

      assert_raise ArgumentError,
                   ~r/invalid argument value for "user_id", require a UUID format string/,
                   fn ->
                     ArgumentHandler.validate_args!(config, request)
                   end
    end

    test "rejects non-string" do
      config = %FunConfig{arg_types: %{"user_id" => :uuid}}
      request = %Request{args: %{"user_id" => 123}}

      assert_raise ArgumentError,
                   ~r/invalid argument value for "user_id", require a UUID format string/,
                   fn ->
                     ArgumentHandler.validate_args!(config, request)
                   end
     end
   end
end
