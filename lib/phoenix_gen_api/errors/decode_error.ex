defmodule PhoenixGenApi.Errors.DecodeError do
  @moduledoc """
  Error raised when request payload decoding fails.

  This exception carries a structured error code so callers can
  differentiate between client errors and internal errors.
  """

  defexception [:message, :code, :details]

  @type t :: %__MODULE__{
          message: String.t(),
          code: :invalid_payload | :missing_field | :internal_error,
          details: term()
        }

  @doc """
  Creates a DecodeError with the given code, message, and optional details.
  """
  @spec exception(code :: atom(), message :: String.t(), details :: term()) :: %__MODULE__{}
  def exception(code, message, details \\ nil) do
    %__MODULE__{message: message, code: code, details: details}
  end
end

defimpl String.Chars, for: PhoenixGenApi.Errors.DecodeError do
  def to_string(%PhoenixGenApi.Errors.DecodeError{message: message}), do: message
end
