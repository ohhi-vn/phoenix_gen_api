defmodule PhoenixGenApi.Structs.Request do
  @moduledoc """
  Request struct for internal using, convert data map from websocket api.

  Data from websocket api has payload like this:

  ```Elixir
  %{
    "request_id" => "request_id",
    "request_type" => "request_type",
    "service" => "service",
    "user_id" => "user_id",
    "device_id" => "device_id",
    "args" => %{}
  }
  ```

  We need to convert it to struct for internal using.

  Like this:

  ```Elixir
  %PhoenixGenApi.Structs.Request{
    request_id: "request_id",
    request_type: "request_type",
    service: "service",
    user_id: "user_id",
    device_id: "device_id",
    args: %{}
  }
  ```

  Explain:
  - user_id: string, user's id in system.
    User's id in system. It need to check permission.

  - device_id: string, device id of current connection.
    Device id of current connection.

  - request_type: string, request type.
    Request type. Using for identify function to call in system.

  - request_id: string, unique id for request. Make by client.
    Unique id for request. Make by client. Using for identify response.

  - service: string, service name.
    Service name. Using for identify service to call in system.

  - args: map, field -> value, arguments for request.
    Arguments for request. Using for call function in system.

  ## Payload Size Validation

  `decode!/1` validates the payload size before deserialization to prevent
  memory exhaustion from oversized requests. The limit is configurable via
  application env:

      config :phoenix_gen_api, :request,
        max_payload_bytes: 1_000_000  # default: 1MB

  Use `max_payload_bytes/0` to read the current configured limit at runtime.

  ## Security Considerations

  - Payload size is checked **before** deserialization to prevent memory
    exhaustion attacks where a client sends an enormous map.
  - The default limit is **1MB** and can be configured per application needs
    via `config :phoenix_gen_api, :request, max_payload_bytes: N`.
  - The check uses `:erlang.external_size/1` (when available) for accurate
    measurement without allocating the full binary. Falls back to
    `byte_size(:erlang.term_to_binary(params))` on older Erlang/OTP releases.
  - If the payload exceeds the limit, `decode!/1` raises an error with the
    configured maximum and the actual measured size.
  """

  alias __MODULE__

  alias PhoenixGenApi.Errors.DecodeError

  @typedoc "Request struct for internal using, convert data map from websocket api."

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          device_id: String.t() | nil,
          request_type: String.t(),
          request_id: String.t(),
          service: String.t(),
          args: map(),
          user_roles: [String.t()] | nil,
          version: String.t() | nil
        }

  @derive Nestru.Decoder
  defstruct [
    # user's id in system.
    :user_id,
    # device id of current connection.
    :device_id,
    # request type.
    :request_type,
    # unique id for request. Make by client.
    :request_id,
    # service name.
    :service,
    # field -> value, arguments for request.
    args: %{},
    # user roles for permission checking.
    user_roles: nil,
    # version of the API request.
    version: nil
  ]

  @default_max_payload_bytes 1_000_000

  @doc """
  Returns the configured maximum payload size in bytes.

  Reads from `config :phoenix_gen_api, :request, max_payload_bytes`.
  Defaults to 1MB (`#{@default_max_payload_bytes}` bytes).
  """
  def max_payload_bytes do
    Application.get_env(:phoenix_gen_api, :request, [])[:max_payload_bytes] ||
      @default_max_payload_bytes
  end

  @doc """
  Create Request from params for convert data map from websocket api.

  Validates payload size before deserialization. Raises if the payload
  exceeds the configured `max_payload_bytes` limit.
  """
  def decode!(params = %{}) do
    validate_payload_size!(params)

    request =
      try do
        Nestru.decode!(params, Request)
      rescue
        e in DecodeError ->
          raise e

        e ->
          exception =
            DecodeError.exception(
              :invalid_payload,
              "Malformed request payload: #{Exception.message(e)}",
              e
            )

          reraise exception, __STACKTRACE__
      end

    request = %{request | args: request.args || %{}}
    request = %{request | user_roles: validate_user_roles(request.user_roles)}

    validate_required_fields!(request)

    request
  end

  defp validate_required_fields!(request) do
    missing =
      []
      |> then(&if blank?(request.request_type), do: ["request_type" | &1], else: &1)
      |> then(&if blank?(request.request_id), do: ["request_id" | &1], else: &1)
      |> then(&if blank?(request.service), do: ["service" | &1], else: &1)

    if missing != [] do
      fields = Enum.reverse(missing) |> Enum.join(", ")
      raise DecodeError, code: :missing_field, message: "Missing required fields: #{fields}"
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp validate_payload_size!(params) do
    max = max_payload_bytes()
    actual = payload_size(params)

    if actual > max do
      msg = "Request payload exceeds maximum size of #{max} bytes (got #{actual} bytes)"
      raise DecodeError, code: :invalid_payload, message: msg
    end
  end

  defp payload_size(params) do
    if function_exported?(:erlang, :external_size, 1) do
      :erlang.external_size(params)
    else
      params |> :erlang.term_to_binary() |> byte_size()
    end
  end

  defp validate_user_roles(nil), do: nil

  defp validate_user_roles(roles) when is_list(roles) do
    Enum.filter(roles, &is_binary/1) |> Enum.reject(&(byte_size(&1) == 0))
  end

  defp validate_user_roles(_), do: nil
end
