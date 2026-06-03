defmodule PhoenixGenApi.Errors.DecodeErrorTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.Errors.DecodeError

  describe "exception/3" do
    test "creates error with code and message" do
      error = DecodeError.exception(:invalid_payload, "bad data")

      assert error.code == :invalid_payload
      assert error.message == "bad data"
      assert is_nil(error.details)
    end

    test "creates error with code, message, and details" do
      original_error = %RuntimeError{message: "original"}
      error = DecodeError.exception(:invalid_payload, "bad data", original_error)

      assert error.code == :invalid_payload
      assert error.message == "bad data"
      assert error.details == original_error
    end

    test "supports :missing_field code" do
      error = DecodeError.exception(:missing_field, "Missing required fields: service")

      assert error.code == :missing_field
      assert error.message == "Missing required fields: service"
    end

    test "supports :internal_error code" do
      error = DecodeError.exception(:internal_error, "something went wrong")

      assert error.code == :internal_error
      assert error.message == "something went wrong"
    end
  end

  describe "String.Chars implementation" do
    test "converts error to string using message" do
      error = DecodeError.exception(:invalid_payload, "bad data")
      assert to_string(error) == "bad data"
    end

    test "converts error with details to string" do
      error = DecodeError.exception(:missing_field, "missing fields", %RuntimeError{})
      assert to_string(error) == "missing fields"
    end
  end

  describe "raising the error" do
    test "raises with correct code and message" do
      assert_raise DecodeError, fn ->
        raise DecodeError, code: :invalid_payload, message: "test error"
      end
    end

    test "raised error preserves code field" do
      try do
        raise DecodeError, code: :missing_field, message: "missing"
      rescue
        e in DecodeError ->
          assert e.code == :missing_field
          assert e.message == "missing"
      end
    end

    test "raised error preserves details field" do
      original = %RuntimeError{message: "original"}

      try do
        raise DecodeError, code: :invalid_payload, message: "wrapper", details: original
      rescue
        e in DecodeError ->
          assert e.details == original
      end
    end

    test "can be caught with rescue block" do
      result =
        try do
          raise DecodeError, code: :invalid_payload, message: "catch me"
        rescue
          e in DecodeError -> {:caught, e.code, e.message}
        end

      assert result == {:caught, :invalid_payload, "catch me"}
    end
  end
end
