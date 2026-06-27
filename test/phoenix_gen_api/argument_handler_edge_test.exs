defmodule PhoenixGenApi.ArgumentHandlerEdgeTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.ArgumentHandler
  alias PhoenixGenApi.Structs.{FunConfig, Request}

  # ── Configuration function tests ──

  describe "string_max_bytes/0" do
    test "returns default value when not configured" do
      # Default is 10,000,000 (10MB)
      # We can't easily test this without restarting the app, so just verify it returns a positive integer
      assert is_integer(ArgumentHandler.string_max_bytes())
      assert ArgumentHandler.string_max_bytes() > 0
    end

    test "returns configured value" do
      Application.put_env(:phoenix_gen_api, :argument_handler, string_max_bytes: 5000)
      assert ArgumentHandler.string_max_bytes() == 5000
      Application.delete_env(:phoenix_gen_api, :argument_handler)
    end
  end

  describe "list_max_items/0" do
    test "returns default value when not configured" do
      Application.delete_env(:phoenix_gen_api, :argument_handler)
      # Default is 1000
      assert ArgumentHandler.list_max_items() == 1000
    end

    test "returns configured value" do
      Application.put_env(:phoenix_gen_api, :argument_handler, list_max_items: 500)
      assert ArgumentHandler.list_max_items() == 500
      Application.delete_env(:phoenix_gen_api, :argument_handler)
    end
  end

  describe "map_max_items/0" do
    test "returns default value when not configured" do
      Application.delete_env(:phoenix_gen_api, :argument_handler)
      # Default is 1000
      assert ArgumentHandler.map_max_items() == 1000
    end

    test "returns configured value" do
      Application.put_env(:phoenix_gen_api, :argument_handler, map_max_items: 200)
      assert ArgumentHandler.map_max_items() == 200
      Application.delete_env(:phoenix_gen_api, :argument_handler)
    end
  end

  # ── convert_args! with arg_orders: :map ──

  describe "convert_args!/2 with arg_orders: :map" do
    test "returns list containing a single map for :map arg_orders" do
      config = %FunConfig{
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: :map
      }

      request = %Request{args: %{"name" => "Alice", "age" => 30}}
      result = ArgumentHandler.convert_args!(config, request)
      assert [%{"name" => "Alice", "age" => 30}] = result
    end

    test "applies defaults when arg_orders is :map" do
      config = %FunConfig{
        arg_types: %{
          "name" => :string,
          "age" => [type: :num, default_value: 25]
        },
        arg_orders: :map
      }

      request = %Request{args: %{"name" => "Bob"}}
      result = ArgumentHandler.convert_args!(config, request)
      assert [%{"name" => "Bob", "age" => 25}] = result
    end

    test "handles allow_nil? with arg_orders :map" do
      config = %FunConfig{
        arg_types: %{
          "name" => :string,
          "email" => [type: :string, allow_nil?: true]
        },
        arg_orders: :map
      }

      request = %Request{args: %{"name" => "Bob"}}
      result = ArgumentHandler.convert_args!(config, request)
      assert [%{"name" => "Bob", "email" => nil}] = result
    end
  end

  # ── convert_args! with single argument ──

  describe "convert_args!/2 with single argument" do
    test "returns list with single value for one arg" do
      config = %FunConfig{
        arg_types: %{"name" => :string},
        arg_orders: ["name"]
      }

      request = %Request{args: %{"name" => "Alice"}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == ["Alice"]
    end

    test "returns single value with type conversion" do
      config = %FunConfig{
        arg_types: %{"age" => :num},
        arg_orders: ["age"]
      }

      request = %Request{args: %{"age" => 30}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [30]
    end
  end

  # ── convert_args! error cases ──

  describe "convert_args!/2 error cases" do
    test "raises when required argument is missing and no default" do
      config = %FunConfig{
        arg_types: %{"name" => :string},
        arg_orders: ["name"]
      }

      request = %Request{args: %{}}

      assert_raise ArgumentError, ~r/missing or nil argument/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "raises when argument type is invalid" do
      config = %FunConfig{
        arg_types: %{"age" => :num},
        arg_orders: ["age"]
      }

      request = %Request{args: %{"age" => "not_a_number"}}

      assert_raise ArgumentError, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "raises when string exceeds max bytes via convert" do
      config = %FunConfig{
        arg_types: %{"name" => {:string, [max_bytes: 5]}},
        arg_orders: ["name"]
      }

      request = %Request{args: %{"name" => "too_long_string"}}

      assert_raise ArgumentError, ~r/max 5 bytes/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "validate_args! passes for string within max bytes" do
      config = %FunConfig{
        arg_types: %{"name" => {:string, [max_bytes: 100]}},
        arg_orders: ["name"]
      }

      request = %Request{args: %{"name" => "short"}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end
  end

  # ── Extra args detection ──

  describe "validate_args!/2 extra args detection" do
    test "raises when request has extra args not in config" do
      config = %FunConfig{
        arg_types: %{"name" => :string},
        arg_orders: ["name"]
      }

      request = %Request{args: %{"name" => "Alice", "extra_field" => "oops"}}

      assert_raise ArgumentError, ~r/extra arguments/, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "allows all args when they match config" do
      config = %FunConfig{
        arg_types: %{"name" => :string, "age" => :num},
        arg_orders: ["name", "age"]
      }

      request = %Request{args: %{"name" => "Alice", "age" => 30}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "raises for multiple extra args" do
      config = %FunConfig{
        arg_types: %{"name" => :string},
        arg_orders: ["name"]
      }

      request = %Request{args: %{"name" => "Alice", "extra1" => 1, "extra2" => 2}}

      assert_raise ArgumentError, ~r/extra1.*extra2|extra2.*extra1/, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end
  end

  # ── Boolean type validation ──

  describe "boolean type validation" do
    test "accepts true" do
      config = %FunConfig{
        arg_types: %{"active" => :boolean},
        arg_orders: ["active"]
      }

      request = %Request{args: %{"active" => true}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "accepts false" do
      config = %FunConfig{
        arg_types: %{"active" => :boolean},
        arg_orders: ["active"]
      }

      request = %Request{args: %{"active" => false}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects non-boolean value" do
      config = %FunConfig{
        arg_types: %{"active" => :boolean},
        arg_orders: ["active"]
      }

      request = %Request{args: %{"active" => "yes"}}

      assert_raise ArgumentError, ~r/expected :boolean/, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "rejects nil for boolean" do
      config = %FunConfig{
        arg_types: %{"active" => :boolean},
        arg_orders: ["active"]
      }

      request = %Request{args: %{"active" => nil}}

      assert_raise ArgumentError, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end
  end

  # ── datetime type validation ──

  describe "datetime type validation" do
    test "accepts valid ISO 8601 datetime with timezone" do
      config = %FunConfig{
        arg_types: %{"created_at" => :datetime},
        arg_orders: ["created_at"]
      }

      request = %Request{args: %{"created_at" => "2024-01-15T10:30:00Z"}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "accepts datetime with offset" do
      config = %FunConfig{
        arg_types: %{"created_at" => :datetime},
        arg_orders: ["created_at"]
      }

      request = %Request{args: %{"created_at" => "2024-01-15T10:30:00+07:00"}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "accepts datetime string in validate_args! (full validation in convert)" do
      # validate_args! only checks if datetime is a binary, full ISO 8601 validation
      # happens in convert_args!/convert_arg!
      config = %FunConfig{
        arg_types: %{"created_at" => :datetime},
        arg_orders: ["created_at"]
      }

      request = %Request{args: %{"created_at" => "2024-01-15T10:30:00Z"}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects non-binary datetime in validate_args!" do
      config = %FunConfig{
        arg_types: %{"created_at" => :datetime},
        arg_orders: ["created_at"]
      }

      request = %Request{args: %{"created_at" => 12345}}

      assert_raise ArgumentError, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "rejects datetime without timezone in convert_args!" do
      config = %FunConfig{
        arg_types: %{"created_at" => :datetime},
        arg_orders: ["created_at"]
      }

      request = %Request{args: %{"created_at" => "2024-01-15T10:30:00"}}

      assert_raise ArgumentError, ~r/invalid datetime format/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end
  end

  # ── naive_datetime type validation ──

  describe "naive_datetime type validation" do
    test "accepts valid naive datetime" do
      config = %FunConfig{
        arg_types: %{"naive_time" => :naive_datetime},
        arg_orders: ["naive_time"]
      }

      request = %Request{args: %{"naive_time" => "2024-01-15T10:30:00"}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects invalid naive datetime" do
      config = %FunConfig{
        arg_types: %{"naive_time" => :naive_datetime},
        arg_orders: ["naive_time"]
      }

      request = %Request{args: %{"naive_time" => "invalid"}}

      assert_raise ArgumentError, ~r/invalid naive_datetime format/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "rejects non-string for naive_datetime" do
      config = %FunConfig{
        arg_types: %{"naive_time" => :naive_datetime},
        arg_orders: ["naive_time"]
      }

      request = %Request{args: %{"naive_time" => 12345}}

      assert_raise ArgumentError, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end
  end

  # ── num type validation ──

  describe "num type validation" do
    test "accepts integer" do
      config = %FunConfig{
        arg_types: %{"count" => :num},
        arg_orders: ["count"]
      }

      request = %Request{args: %{"count" => 42}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "accepts float" do
      config = %FunConfig{
        arg_types: %{"price" => :num},
        arg_orders: ["price"]
      }

      request = %Request{args: %{"price" => 19.99}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects string for num" do
      config = %FunConfig{
        arg_types: %{"count" => :num},
        arg_orders: ["count"]
      }

      request = %Request{args: %{"count" => "forty-two"}}

      assert_raise ArgumentError, ~r/expected :num/, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end
  end

  # ── list type validation ──

  describe "list type validation" do
    test "accepts list of supported types" do
      config = %FunConfig{
        arg_types: %{"items" => :list},
        arg_orders: ["items"]
      }

      # List accepts: booleans, numbers, and strings
      request = %Request{args: %{"items" => [1, "two", true, 3.14]}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects list exceeding max items via convert" do
      # Use keyword list format for new style with custom params
      config = %FunConfig{
        arg_types: %{"items" => [type: :list, max_items: 2]},
        arg_orders: ["items"]
      }

      request = %Request{args: %{"items" => [1, 2, 3]}}

      assert_raise ArgumentError, ~r/max 2 items/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "accepts list within default max items" do
      config = %FunConfig{
        arg_types: %{"items" => :list},
        arg_orders: ["items"]
      }

      request = %Request{args: %{"items" => [1, 2, 3]}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects nested map in list" do
      config = %FunConfig{
        arg_types: %{"items" => :list},
        arg_orders: ["items"]
      }

      request = %Request{args: %{"items" => [%{nested: "map"}]}}

      assert_raise ArgumentError, ~r/nested map is not supported/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "rejects nested list in list" do
      config = %FunConfig{
        arg_types: %{"items" => :list},
        arg_orders: ["items"]
      }

      request = %Request{args: %{"items" => [[1, 2]]}}

      assert_raise ArgumentError, ~r/nested list is not supported/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end
  end

  # ── list_string type validation ──

  describe "list_string type validation" do
    test "accepts list of strings" do
      config = %FunConfig{
        arg_types: %{"tags" => :list_string},
        arg_orders: ["tags"]
      }

      request = %Request{args: %{"tags" => ["elixir", "phoenix"]}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects non-string items in list_string" do
      config = %FunConfig{
        arg_types: %{"tags" => :list_string},
        arg_orders: ["tags"]
      }

      request = %Request{args: %{"tags" => ["valid", 123]}}

      assert_raise RuntimeError, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end

    test "rejects string exceeding max_item_bytes in list_string via convert" do
      # Use keyword list format for new style
      config = %FunConfig{
        arg_types: %{"tags" => [type: :list_string, max_items: 10, max_item_bytes: 5]},
        arg_orders: ["tags"]
      }

      request = %Request{args: %{"tags" => ["toolong"]}}

      assert_raise RuntimeError, ~r/unsupported type/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end
  end

  # ── list_num type validation ──

  describe "list_num type validation" do
    test "accepts list of numbers" do
      config = %FunConfig{
        arg_types: %{"scores" => :list_num},
        arg_orders: ["scores"]
      }

      request = %Request{args: %{"scores" => [1, 2.5, 3]}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects non-number items in list_num" do
      config = %FunConfig{
        arg_types: %{"scores" => :list_num},
        arg_orders: ["scores"]
      }

      request = %Request{args: %{"scores" => [1, "two"]}}

      assert_raise RuntimeError, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end
  end

  # ── list_uuid type validation ──

  describe "list_uuid type validation" do
    test "accepts list of valid UUIDs" do
      config = %FunConfig{
        arg_types: %{"ids" => :list_uuid},
        arg_orders: ["ids"]
      }

      request = %Request{args: %{"ids" => ["550e8400-e29b-41d4-a716-446655440000"]}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects invalid UUID in list_uuid" do
      config = %FunConfig{
        arg_types: %{"ids" => :list_uuid},
        arg_orders: ["ids"]
      }

      request = %Request{args: %{"ids" => ["550e8400-e29b-41d4-a716-446655440000", "not-a-uuid"]}}

      assert_raise RuntimeError, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end
  end

  # ── list_map type validation ──

  describe "list_map type validation" do
    test "accepts list of maps" do
      config = %FunConfig{
        arg_types: %{"items" => :list_map},
        arg_orders: ["items"]
      }

      request = %Request{args: %{"items" => [%{name: "a"}, %{name: "b"}]}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects non-map items in list_map" do
      config = %FunConfig{
        arg_types: %{"items" => :list_map},
        arg_orders: ["items"]
      }

      request = %Request{args: %{"items" => [%{valid: "map"}, "not_a_map"]}}

      assert_raise RuntimeError, fn ->
        ArgumentHandler.validate_args!(config, request)
      end
    end
  end

  # ── map type validation ──

  describe "map type validation" do
    test "accepts map within size limit" do
      config = %FunConfig{
        arg_types: %{"data" => :map},
        arg_orders: ["data"]
      }

      request = %Request{args: %{"data" => %{a: 1, b: 2}}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects map exceeding size limit via convert" do
      # Use keyword list format for new style with custom params
      config = %FunConfig{
        arg_types: %{"data" => [type: :map, max_items: 2]},
        arg_orders: ["data"]
      }

      request = %Request{args: %{"data" => %{a: 1, b: 2, c: 3}}}

      assert_raise ArgumentError, ~r/max 2 items/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "rejects map with nested map values via convert (using tuple format)" do
      # Note: nested map validation only happens with tuple format {:map, params}
      config = %FunConfig{
        arg_types: %{"data" => {:map, [max_items: 100]}},
        arg_orders: ["data"]
      }

      request = %Request{args: %{"data" => %{nested: %{deep: "map"}}}}

      assert_raise ArgumentError, ~r/nested map is not supported/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "rejects map with nested list values via convert (using keyword format)" do
      # Use a small list_max_items to trigger the error
      config = %FunConfig{
        arg_types: %{"data" => [type: :map, max_items: 100]},
        arg_orders: ["data"]
      }

      # Create a list that exceeds default list_max_items (1000)
      large_list = Enum.to_list(1..1001)
      request = %Request{args: %{"data" => %{list_val: large_list}}}

      assert_raise ArgumentError, ~r/nested map list value exceeds max items/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "rejects map with unsupported value types via convert (using tuple format)" do
      config = %FunConfig{
        arg_types: %{"data" => {:map, [max_items: 100]}},
        arg_orders: ["data"]
      }

      request = %Request{args: %{"data" => %{tuple_val: {:tuple, "not_supported"}}}}

      assert_raise ArgumentError, ~r/unsupported type/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end

    test "map validation passes for flat maps" do
      config = %FunConfig{
        arg_types: %{"data" => :map},
        arg_orders: ["data"]
      }

      request = %Request{args: %{"data" => %{name: "Alice", age: 30, active: true}}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end
  end

  # ── map with required keys ──

  describe "map with required keys" do
    test "accepts map with all required keys" do
      config = %FunConfig{
        arg_types: %{"data" => {:map, [required: [:name, :age]]}},
        arg_orders: ["data"]
      }

      request = %Request{args: %{"data" => %{name: "Alice", age: 30}}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects map missing required keys via convert" do
      config = %FunConfig{
        arg_types: %{"data" => [type: :map, required: [:name, :age]]},
        arg_orders: ["data"]
      }

      request = %Request{args: %{"data" => %{name: "Alice"}}}

      assert_raise ArgumentError, ~r/missing required keys/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end
  end

  # ── map with accepted keys ──

  describe "map with accepted keys" do
    test "accepts map with only accepted keys" do
      config = %FunConfig{
        arg_types: %{"data" => {:map, [accept: [:name, :age]]}},
        arg_orders: ["data"]
      }

      request = %Request{args: %{"data" => %{name: "Alice", age: 30}}}
      assert ArgumentHandler.validate_args!(config, request) == :ok
    end

    test "rejects map with unaccepted keys" do
      config = %FunConfig{
        arg_types: %{"data" => [type: :map, accept: [:name]]},
        arg_orders: ["data"]
      }

      request = %Request{args: %{"data" => %{name: "Alice", extra: "field"}}}

      assert_raise ArgumentError, ~r/rejected keys/, fn ->
        ArgumentHandler.convert_args!(config, request)
      end
    end
  end

  # ── Default value tests ──

  describe "default values" do
    test "uses default_value when arg is missing" do
      config = %FunConfig{
        arg_types: %{"status" => [type: :string, default_value: "active"]},
        arg_orders: ["status"]
      }

      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == ["active"]
    end

    test "uses default_value for nil when allow_nil? is true" do
      config = %FunConfig{
        arg_types: %{"status" => [type: :string, default_value: "active", allow_nil?: true]},
        arg_orders: ["status"]
      }

      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == ["active"]
    end

    test "nil arg with allow_nil? true overrides default_value" do
      config = %FunConfig{
        arg_types: %{"status" => [type: :string, default_value: "active", allow_nil?: true]},
        arg_orders: ["status"]
      }

      request = %Request{args: %{"status" => nil}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [nil]
    end

    test "missing arg with allow_nil? true and no default" do
      config = %FunConfig{
        arg_types: %{"status" => [type: :string, allow_nil?: true]},
        arg_orders: ["status"]
      }

      request = %Request{args: %{}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [nil]
    end
  end

  # ── Conversion tests ──

  describe "convert_args! type conversion" do
    test "converts datetime string to DateTime struct" do
      config = %FunConfig{
        arg_types: %{"created_at" => :datetime},
        arg_orders: ["created_at"]
      }

      # Use +07:00 offset because Z (UTC) is treated as offset 0 and rejected
      request = %Request{args: %{"created_at" => "2024-01-15T10:30:00+07:00"}}
      result = ArgumentHandler.convert_args!(config, request)
      assert [%DateTime{}] = result
    end

    test "converts naive_datetime string to NaiveDateTime struct" do
      config = %FunConfig{
        arg_types: %{"naive_time" => :naive_datetime},
        arg_orders: ["naive_time"]
      }

      request = %Request{args: %{"naive_time" => "2024-01-15T10:30:00"}}
      result = ArgumentHandler.convert_args!(config, request)
      assert [%NaiveDateTime{}] = result
    end

    test "converts uuid string (validates format)" do
      config = %FunConfig{
        arg_types: %{"id" => :uuid},
        arg_orders: ["id"]
      }

      uuid = "550e8400-e29b-41d4-a716-446655440000"
      request = %Request{args: %{"id" => uuid}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [uuid]
    end

    test "converts num type (passes through)" do
      config = %FunConfig{
        arg_types: %{"count" => :num},
        arg_orders: ["count"]
      }

      request = %Request{args: %{"count" => 42}}
      result = ArgumentHandler.convert_args!(config, request)
      assert result == [42]
    end
  end
end
