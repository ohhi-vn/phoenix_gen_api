defmodule PhoenixGenApi.Tracer.LogCapture do
  @moduledoc """
  Logger handler that captures raw log lines for traced requests.

  While a process is executing a traced request, it carries the
  `phoenix_gen_api_trace` metadata (a list of `{kind, key}` targets) set by
  `PhoenixGenApi.Tracer.begin_trace/1`. Every `Logger` event emitted by such
  a process is forwarded to the `PhoenixGenApi.Tracer` writer, which appends
  it to the matching per-key trace files as an `event=log` line.

  This handler is transparent: it forwards events to other handlers and does
  not modify or drop them.

  This module also exposes the `console_filter/2` used on the default console
  handler. When the tracer raises the primary log level to capture debug/info
  output for traced requests, that filter keeps untraced low-level messages
  from flooding the console.
  """

  @behaviour :logger_handler

  alias PhoenixGenApi.Tracer

  @trace_metadata_key :phoenix_gen_api_trace
  @trace_request_metadata_key :phoenix_gen_api_trace_request

  @impl true
  def log(%{level: level, meta: meta, msg: msg}, config) do
    capture_level = Map.get(config, :level, :debug)

    if :logger.compare_levels(level, capture_level) != :lt and traced?(meta) do
      targets = Map.get(meta, @trace_metadata_key, [])
      snapshot = Map.get(meta, @trace_request_metadata_key, %{})
      pid = Map.get(config, :tracer_pid)

      line = format_line(level, msg, meta, snapshot)

      Enum.each(targets, fn {kind, key} ->
        send(pid, {:trace_line, kind, key, line})
      end)
    end

    :ok
  end

  def log(_event, _config), do: :ok

  @impl true
  def adding_handler(config), do: {:ok, config}

  @impl true
  def removing_handler(_config), do: :ok

  @impl true
  def filter_config(config), do: config

  @doc """
  Filter installed on the `:default` console handler while the tracer is
  running.

  When the tracer raises the primary log level to its capture level, this
  filter stops messages below the application's normal log level unless they
  belong to a traced request (they carry `phoenix_gen_api_trace` metadata).
  """
  def console_filter(event = %{level: level, meta: meta}, %{level: app_level}) do
    if :logger.compare_levels(level, app_level) == :lt do
      if traced?(meta), do: event, else: :stop
    else
      event
    end
  end

  def console_filter(_event, _config), do: :ignore

  defp traced?(meta) when is_map(meta) do
    Map.get(meta, @trace_metadata_key, []) != []
  end

  defp traced?(_), do: false

  defp format_line(level, msg, meta, snapshot) do
    extra = %{
      "level" => to_string(level),
      "pid" => Tracer.format_value(pid(meta)),
      "mfa" => Tracer.format_value(mfa(meta)),
      "message" => message(msg)
    }

    Tracer.build_trace_line("log", snapshot, extra)
  end

  defp pid(meta) do
    case Map.get(meta, :pid) do
      pid when is_pid(pid) -> pid
      _ -> self()
    end
  end

  defp mfa(meta) do
    case Map.get(meta, :mfa) do
      {mod, fun, arity} when is_atom(mod) and is_atom(fun) and is_integer(arity) ->
        "#{inspect(mod)}.#{fun}/#{arity}"

      other ->
        other
    end
  end

  defp message({_, {:string, chardata}}) do
    safe_chardata_to_string(chardata)
  end

  defp message({_, {:report, report}}), do: Tracer.format_value(report)
  defp message({_, {:format, format, args}}), do: safe_chardata_to_string(:io_lib.format(format, args))
  defp message({_, other}), do: Tracer.format_value(other)

  defp safe_chardata_to_string(chardata) do
    do_chardata_to_string(chardata)
  rescue
    _ -> Tracer.format_value(chardata)
  end

  defp do_chardata_to_string(chardata) do
    chardata |> IO.chardata_to_string() |> Tracer.format_value()
  end
end
