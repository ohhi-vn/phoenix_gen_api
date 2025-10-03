defmodule PhoenixGenApi.Errors.InvalidTypeTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Errors.InvalidType

  describe "exception/1" do
    test "creates error with message for argument name" do
      error = InvalidType.exception("test_arg")

      assert error.message =~ "Invalid type for argument"
      assert error.message =~ "test_arg"
    end

    test "creates error with message for complex argument" do
      error = InvalidType.exception(%{key: "value"})

      assert error.message =~ "Invalid type for argument"
      assert error.message =~ "key"
    end
  end

  describe "String.Chars implementation" do
    test "converts error to string" do
      error = InvalidType.exception("my_arg")
      string = to_string(error)

      assert string =~ "Invalid type for argument"
      assert string =~ "my_arg"
    end
  end

  describe "raising the error" do
    test "raises with correct message" do
      assert_raise InvalidType, ~r/Invalid type for argument/, fn ->
        raise InvalidType, "bad_arg"
      end
    end

    test "can be caught and inspected" do
      try do
        raise InvalidType, "test_field"
      rescue
        e in InvalidType ->
          assert e.message =~ "test_field"
      end
    end
  end
end
