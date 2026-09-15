defmodule PhoenixGenApi.Tracer do
  @moduledoc """
  Request tracing for PhoenixGenApi with per-key log files.

  Traces requests that match a configured `request_type` or `user_id`, writing
  each trace as a `key=value` line to a dedicated log file (one file per
  request type, one file per user id).

  ## Why this is fast

  The hot-path check performed on every executed request is deliberately tiny:

    * a single `:persistent_term` read to know whether tracing is enabled at all
    * two in-memory membership checks against the enabled `request_type` /
      `user_id` sets
    * if nothing matches, the call returns immediately

  Only when a request matches does it dispatch an asynchronous message to the
  writer process, which performs the file I/O. Tracing therefore never blocks
  request execution and adds negligible overhead when disabled or unmatched.

  ## Enabling tracing

  Tracing is fully opt-in. It is disabled by default and only writes when a
  request matches an explicitly enabled request type or user id.

  ### At runtime (functions)

      # Trace a single request type
      PhoenixGenApi.Tracer.enable_request_type("get_user")

      # Trace several request types at once
      PhoenixGenApi.Tracer.enable_request_type(["get_user", "create_order"])

      # Trace all requests for a specific user
      PhoenixGenApi.Tracer.enable_user_id("user_123")

      # Stop tracing
      PhoenixGenApi.Tracer.disable_request_type("get_user")
      PhoenixGenApi.Tracer.disable_user_id("user_123")

  ### Via configuration

      config :phoenix_gen_api, :tracer,
        enabled: true,
        log_dir: "log/phoenix_gen_api_traces",
        max_file_bytes: 50_000_000,
        max_backup_files: 5,
        log_level: :debug,
        request_types: ["get_user"],
        user_ids: ["user_123"]

  Config options:

    * `:enabled` — global on/off switch (default: `false`)
    * `:log_dir` — directory for the per-key trace files (default:
      `"log/phoenix_gen_api_traces"`)
    * `:max_file_bytes` — rotate a trace file once it exceeds this size
      (default: `50_000_000` = 50 MB)
    * `:max_backup_files` — how many rotated `.1`, `.2`, ... backup files to
      keep (default: `5`)
    * `:log_level` — `Logger` level temporarily raised globally while tracing
      is enabled, so debug/info output is captured (default: `:debug`)
    * `:request_types` — request types to trace at startup
    * `:user_ids` — user ids to trace at startup

  ## Trace files

  Files are named after the traced key:

      log/phoenix_gen_api_traces/request_type-get_user.log
      log/phoenix_gen_api_traces/user_id-user_123.log

  When a request matches both an enabled request type and an enabled user id,
  one line is written to each matching file.

  Each line is space-separated `key=value`, e.g.:

      timestamp=2026-08-17T12:00:00.000Z node=app@host event=request_start \
      request_id=req_1 user_id=user_123 device_id=dev_1 request_type=get_user \
      service=user_service version=nil args="%{\"id\" => \"u1\"}"

  ## Tracing every action of a request

  Tracing does not stop at the three lifecycle events. While a request is being
  traced, the trace file records every action the request takes:

    * structured milestone events (config lookup, hooks, rate limit, permission,
      argument conversion, execution, retries, RPC fallback, async/stream
      dispatch, errors)
    * raw `Logger` output emitted by any process that touches the request
      (`event=log` lines with `level`, `pid`, `mfa` and `message`)

  Raw log capture is driven by process metadata: `begin_trace/1` attaches
  `phoenix_gen_api_trace` and `phoenix_gen_api_trace_request` metadata to the
  current process, and worker processes re-apply that metadata so their logs are
  captured too. While tracing is enabled the global `Logger` level is raised to
  `:log_level` so debug/info messages reach the capture handler, and it is
  restored when tracing is disabled.

  The trace context can also be managed by hand:

      ctx = PhoenixGenApi.Tracer.begin_trace(request)  # nil when not traced
      PhoenixGenApi.Tracer.trace_event("my_step", %{"status" => "ok"})
      PhoenixGenApi.Tracer.end_trace(ctx)              # restores metadata

  Events written per traced request:

    * `event=request_start` — emitted when the executor begins handling the
      request, includes the full request (including `args`)
    * `event=config_lookup` — the service config was resolved (`ok`), missing
      (`not_found`) or disabled
    * `event=hook_before` — a `before_execute` hook ran (`ok`) or failed
    * `event=rate_limit` — rate limiter decision: `allowed`, `limited`
      (with `retry_after_ms`) or `error`
    * `event=permission` — emitted after the permission check, includes
      `permission=allowed|denied` and `permission_mode`
    * `event=arguments` — argument conversion succeeded (with `count`) or failed
    * `event=execution` — the MFA was invoked, with `mode=local|remote` and `mfa`
    * `event=error` — execution raised/exited/errored, with `kind` and `error`
    * `event=retry` / `event=retry_exhausted` — local and remote retry attempts
    * `event=rpc_fallback` — a remote node failed and the request fell back
    * `event=async` / `event=stream` — async/stream dispatch (`queued`,
      `queue_full`, `started`, `timeout`, `error`)
    * `event=hook_after` — an `after_execute` hook ran (`ok`) or failed
    * `event=log` — a raw `Logger` line emitted during the trace
    * `event=request_end` — emitted when execution finishes, includes
      `success`, `async`, `duration_us` and `error` (if any)

  ## Inspecting state

      PhoenixGenApi.Tracer.enabled?()
      PhoenixGenApi.Tracer.enabled_request_types()
      PhoenixGenApi.Tracer.enabled_user_ids()
      PhoenixGenApi.Tracer.status()
  """

  use GenServer

  alias PhoenixGenApi.Structs.{FunConfig, Request, Response}
  alias PhoenixGenApi.Tracer.LogCapture

  require Logger

  @enabled_key :phoenix_gen_api_tracer_enabled
  @membership_key :phoenix_gen_api_tracer_membership
  @empty_membership %{request_types: %{}, user_ids: %{}}

  @trace_metadata_key :phoenix_gen_api_trace
  @trace_request_metadata_key :phoenix_gen_api_trace_request

  @log_capture_handler_id PhoenixGenApi.Tracer.LogCapture
  @console_suppress_filter_id :phoenix_gen_api_trace_console

  @log_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  @default_log_dir "log/phoenix_gen_api_traces"
  @default_max_file_bytes 50_000_000
  @default_max_backup_files 5
  @default_capture_level :debug

  # ──────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────

  @doc """
  Starts the tracer writer process and loads the `:tracer` config.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enables tracing for one or more request types.

  Accepts a single binary or a list of binaries.
  """
  @spec enable_request_type(String.t() | [String.t()]) :: :ok
  def enable_request_type(request_types) when is_list(request_types) do
    Enum.each(request_types, &enable_request_type/1)
    :ok
  end

  def enable_request_type(request_type)
      when is_binary(request_type) and byte_size(request_type) > 0 do
    update_membership(:request_types, &Map.put(&1, request_type, true))
    :ok
  end

  def enable_request_type(_), do: :ok

  @doc """
  Disables tracing for one or more request types.
  """
  @spec disable_request_type(String.t() | [String.t()]) :: :ok
  def disable_request_type(request_types) when is_list(request_types) do
    Enum.each(request_types, &disable_request_type/1)
    :ok
  end

  def disable_request_type(request_type)
      when is_binary(request_type) and byte_size(request_type) > 0 do
    update_membership(:request_types, &Map.delete(&1, request_type))
    :ok
  end

  def disable_request_type(_), do: :ok

  @doc """
  Enables tracing for one or more user ids.
  """
  @spec enable_user_id(String.t() | [String.t()]) :: :ok
  def enable_user_id(user_ids) when is_list(user_ids) do
    Enum.each(user_ids, &enable_user_id/1)
    :ok
  end

  def enable_user_id(user_id) when is_binary(user_id) and byte_size(user_id) > 0 do
    update_membership(:user_ids, &Map.put(&1, user_id, true))
    :ok
  end

  def enable_user_id(_), do: :ok

  @doc """
  Disables tracing for one or more user ids.
  """
  @spec disable_user_id(String.t() | [String.t()]) :: :ok
  def disable_user_id(user_ids) when is_list(user_ids) do
    Enum.each(user_ids, &disable_user_id/1)
    :ok
  end

  def disable_user_id(user_id) when is_binary(user_id) and byte_size(user_id) > 0 do
    update_membership(:user_ids, &Map.delete(&1, user_id))
    :ok
  end

  def disable_user_id(_), do: :ok

  @doc """
  Returns the list of currently traced request types.
  """
  @spec enabled_request_types() :: [String.t()]
  def enabled_request_types do
    read_membership().request_types |> Map.keys()
  end

  @doc """
  Returns the list of currently traced user ids.
  """
  @spec enabled_user_ids() :: [String.t()]
  def enabled_user_ids do
    read_membership().user_ids |> Map.keys()
  end

  @doc """
  Returns `true` when tracing is globally enabled.

  Note: tracing is only written for requests that also match an enabled
  request type or user id.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :persistent_term.get(@enabled_key, false)
  end

  @doc """
  Enables or disables tracing globally at runtime.

  While tracing is enabled, the primary log level is raised to the configured
  `:log_level` (default `:debug`) so that debug/info output from traced
  requests can be captured; the previous level is restored when tracing is
  disabled. Low-level messages that do not belong to a traced request remain
  filtered out of the console.
  """
  @spec set_enabled(boolean()) :: :ok
  def set_enabled(enabled) do
    enabled = normalize_bool(enabled)

    case Process.whereis(__MODULE__) do
      nil ->
        :persistent_term.put(@enabled_key, enabled)
        :ok

      pid ->
        GenServer.call(pid, {:set_enabled, enabled})
    end
  end

  @doc """
  Clears all traced request types and user ids.
  """
  @spec clear() :: :ok
  def clear do
    :persistent_term.put(@membership_key, @empty_membership)
    :ok
  end

  @doc """
  Blocks until the writer has processed all pending trace messages.

  Intended for tests and administrative use; normal production code should
  rely on the asynchronous writer.
  """
  @spec flush() :: :ok | :error
  def flush do
    case Process.whereis(__MODULE__) do
      nil -> :error
      pid -> GenServer.call(pid, :flush)
    end
  end

  @doc """
  Updates writer settings at runtime.

  Accepts a keyword list with any of `:log_dir`, `:max_file_bytes`, or
  `:max_backup_files`. Open trace files are not relocated; the new settings
  apply to subsequently opened files.
  """
  @spec configure(keyword()) :: :ok | {:error, :not_started}
  def configure(opts) when is_list(opts) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      pid -> GenServer.call(pid, {:configure, opts})
    end
  end

  @doc """
  Returns a status snapshot including config, enabled keys and open trace files.
  """
  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      nil ->
        %{
          started: false,
          enabled: enabled?(),
          request_types: enabled_request_types(),
          user_ids: enabled_user_ids(),
          log_dir: log_dir_from_config(),
          capture_level: capture_level_from_config(),
          log_level: Logger.level(),
          files: %{}
        }

      pid ->
        GenServer.call(pid, :status)
    end
  end

  @doc """
  Hot-path hook called by the executor when a request starts executing.

  No-op when tracing is disabled or the request matches nothing. Cheap by
  design: two in-memory membership lookups and, only on match, an
  asynchronous message to the writer.
  """
  @spec trace_request(Request.t()) :: :ok
  def trace_request(request = %Request{}) do
    if enabled?() do
      case traced_targets(request) do
        [] ->
          :ok

        targets ->
          line = build_trace_line("request_start", request, %{"args" => request.args})
          dispatch(targets, line)
          :ok
      end
    else
      :ok
    end
  end

  def trace_request(_), do: :ok

  @doc """
  Traces the permission check result for a request.

  `result` is `:allowed` or `:denied`. Includes the permission mode
  (e.g. `{:arg, "user_id"}` or `{:callback, {mod, fun, args}}`).
  """
  @spec trace_permission(Request.t(), FunConfig.t(), :allowed | :denied) :: :ok
  def trace_permission(request = %Request{}, fun_config = %FunConfig{}, result)
      when result in [:allowed, :denied] do
    if enabled?() do
      line =
        build_trace_line("permission", request, %{
          "permission" => to_string(result),
          "permission_mode" => permission_mode(fun_config)
        })

      dispatch_if_traced(request, line)
    else
      :ok
    end
  end

  def trace_permission(_, _, _), do: :ok

  @doc """
  Traces the final execution result of a request.

  `result` is the value returned by the executor (a `%Response{}`, an
  `{:ok, :no_response}` tuple, or an exception-derived error).
  """
  @spec trace_result(Request.t(), term(), non_neg_integer()) :: :ok
  def trace_result(request = %Request{}, result, duration_us) do
    if enabled?() do
      {success, async, error} = summarize_result(result)

      line =
        build_trace_line("request_end", request, %{
          "success" => to_string(success),
          "async" => to_string(async),
          "duration_us" => duration_us,
          "error" => error
        })

      dispatch_if_traced(request, line)
    else
      :ok
    end
  end

  def trace_result(_, _, _), do: :ok

  @doc """
  Starts a trace context for a request in the current process.

  When the request matches an enabled request type or user id, this writes the
  `request_start` line and attaches trace metadata to the current process so
  that both `trace_event/2` calls and raw `Logger` output emitted while the
  request is processed are captured into the matching trace files.

  Returns `nil` when the request is not traced; otherwise a context that must
  be passed to `end_trace/1` to restore the process metadata.
  """
  @spec begin_trace(Request.t()) :: {keyword(), [{atom(), String.t()}]} | nil
  def begin_trace(request = %Request{}) do
    if enabled?() do
      case traced_targets(request) do
        [] ->
          nil

        targets ->
          trace_request(request)
          previous = Logger.metadata()

          Logger.metadata(%{
            @trace_metadata_key => targets,
            @trace_request_metadata_key => request_snapshot(request)
          })

          {previous, targets}
      end
    else
      nil
    end
  end

  def begin_trace(_), do: nil

  @doc """
  Ends a trace context started with `begin_trace/1`, restoring the process
  metadata to its previous state.
  """
  @spec end_trace({keyword(), term()} | nil) :: :ok
  def end_trace({previous, _targets}) do
    Logger.reset_metadata(previous)
    :ok
  end

  def end_trace(nil), do: :ok

  @doc """
  Writes a structured milestone event for the request currently being traced
  in the current process.

  Requires an active trace context (set by `begin_trace/1` or
  `apply_trace_metadata/1`). The event line includes the traced request's
  context fields plus `extra` (a string-keyed map of `key => value`).
  """
  @spec trace_event(String.t(), map()) :: :ok
  def trace_event(event, extra) when is_binary(event) and is_map(extra) do
    metadata = Logger.metadata()

    case Keyword.fetch(metadata, @trace_metadata_key) do
      {:ok, targets} when targets != [] ->
        snapshot = Keyword.get(metadata, @trace_request_metadata_key, %{})
        line = build_trace_line(event, snapshot, extra)
        dispatch(targets, line)
        :ok

      _ ->
        :ok
    end
  end

  def trace_event(_, _), do: :ok

  @doc """
  Attaches trace metadata to the current process when the given request is
  traced.

  Used by processes that continue request execution in a separate process
  (e.g. `PhoenixGenApi.StreamCall`), so their `Logger` output is captured.
  """
  @spec apply_trace_metadata(Request.t()) :: :ok
  def apply_trace_metadata(request = %Request{}) do
    if enabled?() do
      case traced_targets(request) do
        [] ->
          :ok

        targets ->
          Logger.metadata(%{
            @trace_metadata_key => targets,
            @trace_request_metadata_key => request_snapshot(request)
          })

          :ok
      end
    else
      :ok
    end
  end

  def apply_trace_metadata(_), do: :ok

  # ──────────────────────────────────────────────
  # GenServer callbacks
  # ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    config = Application.get_env(:phoenix_gen_api, :tracer, [])

    enabled = config |> Keyword.get(:enabled, false) |> normalize_bool()
    request_types = config |> Keyword.get(:request_types, []) |> normalize_keys()
    user_ids = config |> Keyword.get(:user_ids, []) |> normalize_keys()

    capture_level = config |> Keyword.get(:log_level, @default_capture_level) |> normalize_level()
    app_level = :logger.get_primary_config() |> Map.get(:level, :warning)

    :ok = attach_log_capture(capture_level)
    :ok = install_console_suppress(app_level)
    if enabled, do: raise_capture_level(capture_level)

    membership = %{
      request_types: Map.new(request_types, &{&1, true}),
      user_ids: Map.new(user_ids, &{&1, true})
    }

    :persistent_term.put(@enabled_key, enabled)
    :persistent_term.put(@membership_key, membership)

    state = %{
      log_dir: Keyword.get(config, :log_dir, @default_log_dir),
      max_file_bytes: Keyword.get(config, :max_file_bytes, @default_max_file_bytes),
      max_backup_files: Keyword.get(config, :max_backup_files, @default_max_backup_files),
      capture_level: capture_level,
      app_level: app_level,
      files: %{}
    }

    Logger.info(
      "[Tracer] started, enabled: #{inspect(enabled)}, request_types: #{inspect(request_types)}, user_ids: #{inspect(user_ids)}, log_dir: #{inspect(state.log_dir)}, capture_level: #{inspect(capture_level)}"
    )

    {:ok, state}
  end

  @impl true
  def handle_info({:trace_line, kind, key, line}, state) do
    path = file_path(state.log_dir, kind, key)
    {:noreply, write_line(state, path, line)}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    Enum.each(state.files, fn {_path, {_size, device}} ->
      :file.sync(device)
    end)

    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    reply = %{
      started: true,
      enabled: enabled?(),
      request_types: enabled_request_types(),
      user_ids: enabled_user_ids(),
      log_dir: state.log_dir,
      max_file_bytes: state.max_file_bytes,
      max_backup_files: state.max_backup_files,
      capture_level: state.capture_level,
      log_level: Logger.level(),
      files: Map.new(state.files, fn {path, {size, _device}} -> {path, size} end)
    }

    {:reply, reply, state}
  end

  def handle_call({:set_enabled, true}, _from, state) do
    :persistent_term.put(@enabled_key, true)
    raise_capture_level(state.capture_level)
    {:reply, :ok, state}
  end

  def handle_call({:set_enabled, false}, _from, state) do
    :persistent_term.put(@enabled_key, false)
    restore_app_level(state.app_level)
    {:reply, :ok, state}
  end

  def handle_call({:configure, opts}, _from, state) do
    state = %{
      state
      | log_dir: Keyword.get(opts, :log_dir, state.log_dir),
        max_file_bytes: Keyword.get(opts, :max_file_bytes, state.max_file_bytes),
        max_backup_files: Keyword.get(opts, :max_backup_files, state.max_backup_files)
    }

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    :logger.remove_handler(@log_capture_handler_id)
    :logger.remove_handler_filter(:default, @console_suppress_filter_id)
    restore_app_level(state.app_level)

    Enum.each(state.files, fn {_path, {_size, device}} -> :file.close(device) end)
    :ok
  end

  # ──────────────────────────────────────────────
  # Membership helpers (persistent_term, hot path)
  # ──────────────────────────────────────────────

  defp read_membership do
    :persistent_term.get(@membership_key, @empty_membership)
  end

  defp update_membership(kind, fun) do
    membership = read_membership()
    :persistent_term.put(@membership_key, Map.update!(membership, kind, fun))
    :ok
  end

  defp traced_targets(request) do
    membership = read_membership()

    []
    |> add_target_if(membership, :request_type, request.request_type)
    |> add_target_if(membership, :user_id, request.user_id)
  end

  defp add_target_if(targets, _membership, _kind, value)
       when not is_binary(value) or byte_size(value) == 0,
       do: targets

  defp add_target_if(targets, membership, kind, value) do
    map = if kind == :request_type, do: membership.request_types, else: membership.user_ids

    if is_map_key(map, value) do
      [{kind, value} | targets]
    else
      targets
    end
  end

  defp dispatch_if_traced(request, line) do
    case traced_targets(request) do
      [] -> :ok
      targets -> dispatch(targets, line)
    end
  end

  defp dispatch(targets, line) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        Enum.each(targets, fn {kind, key} ->
          send(pid, {:trace_line, kind, key, line})
        end)

        :ok
    end
  end

  # ──────────────────────────────────────────────
  # Line building / rendering
  # ──────────────────────────────────────────────

  @doc false
  def build_trace_line(event, request, extra) do
    base = %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "node" => to_string(Node.self()),
      "event" => event,
      "request_id" => request.request_id,
      "user_id" => request.user_id,
      "device_id" => request.device_id,
      "request_type" => request.request_type,
      "service" => request.service,
      "version" => request.version
    }

    render_line(Map.merge(base, extra))
  end

  defp render_line(pairs) do
    Enum.map_join(pairs, " ", fn {key, value} -> "#{key}=#{format_value(value)}" end)
  end

  @doc false
  def format_value(nil), do: "nil"
  def format_value(true), do: "true"
  def format_value(false), do: "false"

  def format_value(value) when is_binary(value) do
    if String.contains?(value, [" ", "=", "\"", "\n", "\t"]) do
      inspect(value)
    else
      value
    end
  end

  def format_value(value) when is_integer(value), do: Integer.to_string(value)
  def format_value(value) when is_float(value), do: Float.to_string(value)
  def format_value(value) when is_atom(value), do: to_string(value)
  def format_value(value), do: inspect(value)

  defp request_snapshot(request) do
    %{
      request_id: request.request_id,
      user_id: request.user_id,
      device_id: request.device_id,
      request_type: request.request_type,
      service: request.service,
      version: request.version
    }
  end

  defp permission_mode(%FunConfig{permission_callback: {mod, fun, args}})
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    {:callback, {mod, fun, args}}
  end

  defp permission_mode(%FunConfig{check_permission: mode}), do: mode

  defp summarize_result(result = %Response{}) do
    {result.success, result.async, result.error}
  end

  defp summarize_result({:ok, :no_response}), do: {true, true, nil}
  defp summarize_result(result = {:error, _}), do: {false, false, result}
  defp summarize_result(other), do: {true, false, other}

  # ──────────────────────────────────────────────
  # File writer
  # ──────────────────────────────────────────────

  defp file_path(log_dir, kind, key) do
    Path.join(log_dir, "#{kind}-#{sanitize_key(key)}.log")
  end

  defp sanitize_key(key) when is_binary(key) do
    sanitized =
      key
      |> String.replace(~r/[\/\\:*?"<>|\s]/, "_")
      |> String.trim()

    if sanitized == "", do: "empty", else: sanitized
  end

  defp sanitize_key(key), do: inspect(key)

  defp write_line(state, path, line) do
    case Map.get(state.files, path) do
      nil ->
        with {:ok, device} <- open_file(path),
             :ok <- do_write(device, line) do
          %{state | files: Map.put(state.files, path, {byte_size(line) + 1, device})}
        else
          {:error, reason} ->
            Logger.error("[Tracer] failed to write trace file #{path}: #{inspect(reason)}")
            state
        end

      {size, device} ->
        if size + byte_size(line) + 1 > state.max_file_bytes do
          rotate_file(state, path, device)
          write_line(%{state | files: Map.delete(state.files, path)}, path, line)
        else
          case do_write(device, line) do
            :ok ->
              %{state | files: Map.put(state.files, path, {size + byte_size(line) + 1, device})}

            {:error, reason} ->
              :file.close(device)
              Logger.error("[Tracer] failed to write trace file #{path}: #{inspect(reason)}")
              %{state | files: Map.delete(state.files, path)}
          end
        end
    end
  end

  defp do_write(device, line) do
    case :file.write(device, [line, "\n"]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_file(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, device} <- :file.open(path, [:append, :raw, {:delayed_write, 4096, 200}]) do
      {:ok, device}
    else
      {:error, reason} ->
        Logger.error("[Tracer] cannot open trace file #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp rotate_file(state, path, device) do
    :file.close(device)

    backup_count = max(state.max_backup_files, 1)

    Enum.each(backup_count..1//-1, fn i ->
      src = "#{path}.#{i}"
      dst = "#{path}.#{i + 1}"
      if File.exists?(src), do: File.rename(src, dst)
    end)

    File.rename(path, "#{path}.1")
    Logger.info("[Tracer] rotated trace file #{path}")
    :ok
  end

  # ──────────────────────────────────────────────
  # Config normalization
  # ──────────────────────────────────────────────

  defp normalize_bool(value) when value in [true, false], do: value
  defp normalize_bool("true"), do: true
  defp normalize_bool("false"), do: false
  defp normalize_bool(_), do: false

  defp normalize_level(level) when level in @log_levels, do: level

  defp normalize_level(level) when is_binary(level) do
    case level do
      "debug" -> :debug
      "info" -> :info
      "notice" -> :notice
      "warn" -> :warning
      "warning" -> :warning
      "error" -> :error
      "critical" -> :critical
      "alert" -> :alert
      "emergency" -> :emergency
      _ -> @default_capture_level
    end
  end

  defp normalize_level(_), do: @default_capture_level

  # ──────────────────────────────────────────────
  # Logger capture plumbing
  # ──────────────────────────────────────────────

  defp attach_log_capture(capture_level) do
    # Remove any stale handler left by a brutal kill, then re-attach.
    :logger.remove_handler(@log_capture_handler_id)

    config = %{tracer_pid: self(), level: capture_level}

    case :logger.add_handler(@log_capture_handler_id, PhoenixGenApi.Tracer.LogCapture, config) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[Tracer] failed to attach log capture handler: #{inspect(reason)}")
        :ok
    end
  end

  defp install_console_suppress(app_level) do
    :logger.remove_handler_filter(:default, @console_suppress_filter_id)

    filter = {&LogCapture.console_filter/2, %{level: app_level}}
    :logger.add_handler_filter(:default, @console_suppress_filter_id, filter)
    :ok
  end

  defp raise_capture_level(level) do
    :logger.set_primary_config(:level, level)
    :ok
  end

  defp restore_app_level(level) do
    :logger.set_primary_config(:level, level)
    :ok
  end

  defp normalize_keys(nil), do: []
  defp normalize_keys(value) when is_binary(value) and byte_size(value) > 0, do: [value]

  defp normalize_keys(value) when is_list(value) do
    Enum.filter(value, &(is_binary(&1) and byte_size(&1) > 0))
  end

  defp normalize_keys(_), do: []

  defp log_dir_from_config do
    Application.get_env(:phoenix_gen_api, :tracer, [])
    |> Keyword.get(:log_dir, @default_log_dir)
  end

  defp capture_level_from_config do
    Application.get_env(:phoenix_gen_api, :tracer, [])
    |> Keyword.get(:log_level, @default_capture_level)
    |> normalize_level()
  end
end
