defmodule PhoenixGenApi.LogContext do
  @moduledoc """
  Canonical log context helpers for PhoenixGenApi.

  Every library log line is expected to carry a `[ModuleName] event=<snake_case>`
  prefix followed by the human-readable message and inline `key=value` fields.
  This module owns the key vocabulary, value formatting, request-scoped Logger
  metadata, and the redaction/verbose-payload policy so the format stays
  consistent across modules.

  ## Context keys

    * `:event` - machine-searchable event name
    * `:request_id` - originating request id
    * `:request_type` - requested API/function name
    * `:service` - owning service name
    * `:user_id` - calling user
    * `:node` - node the line is about (current node by default)
    * `:origin_node` - node that initiated a push
    * `:config_version` - pushed config version, when relevant
    * `:version` - configuration version, when relevant

  Missing request values render as `unknown` so keys are never silently
  dropped, while fields that are intentionally absent can be omitted.

  ## Metadata

  `put/1`, `with_context/2`, and `with_metadata/2` install Logger metadata and
  restore the previous values afterwards. The inline fields remain the
  authoritative source: consumers whose formatter ignores metadata still get a
  traceable line.
  """

  alias PhoenixGenApi.Structs.{FunConfig, Request}

  @keys [
    :event,
    :request_id,
    :request_type,
    :service,
    :user_id,
    :config_version,
    :node,
    :origin_node,
    :version
  ]

  @type fields :: keyword() | map()

  @doc "Returns the canonical context keys used by the library."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  Builds a `[Module] event=<name> key=value...` line without a message.
  """
  @spec event(String.t() | atom(), atom() | String.t(), fields()) :: String.t()
  def event(module, event, fields \\ []) do
    "[#{module}] event=#{event_name(event)}" <> fields_text(fields)
  end

  @doc """
  Builds a `[Module] event=<name> <message> key=value...` line.

  The existing message wording is preserved so current greps keep working.
  """
  @spec line(String.t() | atom(), atom() | String.t(), String.t() | nil, fields()) ::
          String.t()
  def line(module, event, message, fields \\ []) do
    message_text =
      case message do
        nil -> ""
        "" -> ""
        text -> " " <> text
      end

    "[#{module}] event=#{event_name(event)}" <> message_text <> fields_text(fields)
  end

  @doc """
  Returns request-scoped fields for log lines and Logger metadata.

  Unknown request values become `:unknown` so the formatter renders `unknown`
  instead of dropping the key.
  """
  @spec request_context(Request.t(), FunConfig.t() | nil) :: keyword()
  def request_context(%Request{} = request, fun_config \\ nil) do
    [
      request_id: value(request.request_id),
      request_type: value(request.request_type),
      service: value(request.service),
      user_id: value(request.user_id),
      node: node()
    ] ++ version_field(fun_config)
  end

  @doc """
  Returns coarse fields from a raw request payload (before decoding).

  Used at channel entry so decode failures still carry the request identity.
  Payload keys are expected to be strings, matching Phoenix channel payloads.
  """
  @spec payload_context(term(), module() | nil) :: keyword()
  def payload_context(payload, module \\ nil) do
    request_id = payload_field(payload, "request_id")
    request_type = payload_field(payload, "request_type")
    service = payload_field(payload, "service")
    user_id = payload_field(payload, "user_id")

    fields = [
      request_id: value(request_id),
      request_type: value(request_type),
      service: value(service),
      user_id: value(user_id),
      node: node()
    ]

    case module do
      nil -> fields
      module -> Keyword.put(fields, :module, module)
    end
  end

  @doc """
  Returns the request/config context currently installed as Logger metadata.

  Extra fields override base keys and are appended in order. Used by modules
  whose log sites do not receive the `%Request{}` directly.
  """
  @spec current(fields()) :: keyword()
  def current(extra \\ []) do
    metadata = Logger.metadata()

    base =
      for key <- @keys,
          key != :event,
          Keyword.has_key?(metadata, key) do
        {key, value(Keyword.get(metadata, key))}
      end

    Keyword.merge(base, extra)
  end

  @doc "Normalizes a value for rendering; `nil` becomes `:unknown`."
  @spec value(term()) :: term()
  def value(nil), do: :unknown
  def value(value), do: value

  @doc """
  Returns identifying fields from a response-like term for result log lines.

  Responses carry `request_id` but usually not `request_type`/`service`; those
  render as `unknown` rather than being dropped.
  """
  @spec result_context(term()) :: keyword()
  def result_context(result) when is_map(result) do
    [
      request_id: value(Map.get(result, :request_id)),
      request_type: value(Map.get(result, :request_type)),
      service: value(Map.get(result, :service))
    ]
  end

  def result_context(_result) do
    [request_id: :unknown, request_type: :unknown, service: :unknown]
  end

  @doc "Returns a redacted placeholder for secrets."
  @spec sensitive(term()) :: String.t()
  def sensitive(_value), do: "<redacted>"

  @doc """
  Returns the raw payload when verbose payload logging is enabled, otherwise
  the `:redacted` placeholder. The log formatter renders the value, so callers
  must never inspect it themselves.
  """
  @spec payload(term()) :: term()
  def payload(payload) do
    if verbose_payloads?(), do: payload, else: :redacted
  end

  @doc """
  Returns a cheap, non-sensitive summary of a payload: size and top-level keys.
  """
  @spec payload_summary(term()) :: String.t()
  def payload_summary(payload) when is_map(payload) do
    "size=#{payload_size(payload)} keys=#{inspect(Map.keys(payload), limit: 20)}"
  end

  def payload_summary(payload) when is_list(payload) do
    "size=#{length(payload)}"
  end

  def payload_summary(payload) when is_binary(payload) do
    "bytes=#{byte_size(payload)}"
  end

  def payload_summary(nil), do: "size=0"

  def payload_summary(payload) do
    "type=#{inspect(payload |> type_name())}"
  end

  @doc "Returns the external term size of a payload, with a safe fallback."
  @spec payload_size(term()) :: non_neg_integer()
  def payload_size(payload) do
    if function_exported?(:erlang, :external_size, 1) do
      :erlang.external_size(payload)
    else
      payload |> :erlang.term_to_binary() |> byte_size()
    end
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  @doc "Returns true when verbose payload logging is explicitly enabled."
  @spec verbose_payloads?() :: boolean()
  def verbose_payloads? do
    Application.get_env(:phoenix_gen_api, :log_verbose_payloads, false) == true
  end

  @doc """
  Installs context fields as Logger metadata and returns the previous metadata
  so the caller can restore it with `Logger.reset_metadata/1`.
  """
  @spec put(fields()) :: keyword()
  def put(fields) do
    previous = Logger.metadata()
    Logger.metadata(metadata(fields))
    previous
  end

  @doc """
  Runs `fun` with context fields installed as Logger metadata.

  The previous metadata is restored with `Logger.reset_metadata/1` in an
  `after` block, including when `fun` raises or exits.
  """
  @spec with_context(fields(), (-> result)) :: result when result: term()
  def with_context(fields, fun) when is_function(fun, 0) do
    with_metadata(metadata(fields), fun)
  end

  @doc """
  Runs `fun` with the given Logger metadata, restoring the previous metadata
  afterwards. Used to propagate an originating process's context into spawned
  async, stream, or worker-pool work.
  """
  @spec with_metadata(keyword(), (-> result)) :: result when result: term()
  def with_metadata(metadata, fun) when is_list(metadata) and is_function(fun, 0) do
    previous = Logger.metadata()
    Logger.metadata(metadata)

    try do
      fun.()
    after
      Logger.reset_metadata(previous)
    end
  end

  defp version_field(nil), do: []
  defp version_field(%FunConfig{version: version}), do: [version: value(version)]

  defp payload_field(payload, key) when is_map(payload), do: Map.get(payload, key)
  defp payload_field(_payload, _key), do: nil

  defp event_name(event) when is_atom(event), do: Atom.to_string(event)
  defp event_name(event) when is_binary(event), do: event
  defp event_name(event), do: to_string(event)

  defp fields_text(fields) do
    pairs = fields |> Enum.reject(fn {key, _value} -> key == :event end)

    case pairs do
      [] ->
        ""

      pairs ->
        " " <>
          Enum.map_join(pairs, " ", fn {key, value} ->
            "#{key}=#{format_value(value)}"
          end)
    end
  end

  defp format_value(:unknown), do: "unknown"
  defp format_value(:redacted), do: "<redacted>"
  defp format_value(nil), do: "unknown"
  defp format_value(value) when is_binary(value), do: inspect(value, printable_limit: 512)
  defp format_value(value) when is_atom(value), do: inspect(value)
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_value(value) when is_float(value), do: Float.to_string(value)

  defp format_value(value) do
    inspect(value, limit: 20, printable_limit: 512)
  end

  defp metadata(fields) do
    Enum.map(fields, fn {key, value} -> {key, value} end)
  end

  @doc "Returns the coarse type name of a term for log fields."
  @spec type_name(term()) :: atom()
  def type_name(value) when is_map(value), do: :map
  def type_name(value) when is_list(value), do: :list
  def type_name(value) when is_tuple(value), do: :tuple
  def type_name(value) when is_binary(value), do: :binary
  def type_name(value) when is_atom(value), do: :atom
  def type_name(value) when is_integer(value), do: :integer
  def type_name(value) when is_float(value), do: :float
  def type_name(value) when is_pid(value), do: :pid
  def type_name(value) when is_reference(value), do: :reference
  def type_name(_value), do: :term
end
