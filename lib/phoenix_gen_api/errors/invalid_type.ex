defmodule PhoenixGenApi.Errors.InvalidType do
  @moduledoc """
  Error raised when an argument has an invalid type.
  """

  defexception [:message]

  @doc """
  Create a new InvalidType error.
  """
  def exception(arg_name) do
    %__MODULE__{
      message: "Invalid type for argument '#{inspect arg_name}'"
    }
  end
end

defimpl String.Chars, for: PhoenixGenApi.Errors.InvalidType do
  def to_string(%PhoenixGenApi.Errors.InvalidType{message: message}) do
    message
  end
end
