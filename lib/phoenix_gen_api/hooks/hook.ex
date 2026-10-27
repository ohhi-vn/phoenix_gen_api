defmodule PhoenixGenApi.Hooks do
  @moduledoc """
  Provides before/after execution hooks for `FunConfig`.

  Hooks allow users to run custom code before and/or after a function is executed
  through the API. They are configured per-function via the `before_execute` and
  `after_execute` fields in `FunConfig`.

  ## Hook Signature

  Hooks are specified as MFA tuples:

    - `{module, function}` — Calls `module.function(request, fun_config)` for before,
      or `module.function(request, fun_config, result)` for after.
    - `{module, function, extra_args}` — Appends extra arguments after the standard ones.

  ### Before execute

  Must return one of:

    - `{:ok, request, fun_config}` — Proceed with (possibly modified) request/config.
    - `{:error, reason}` — Abort execution and return an error response.

  ### After execute

  Must return the (possibly modified) result. Any other return value is ignored and
  the original result is preserved.

  ## Telemetry

  Hooks emit telemetry events at:

    - `[:phoenix_gen_api, :hook, :before, :start]`
    - `[:phoenix_gen_api, :hook, :before, :stop]`
    - `[:phoenix_gen_api, :hook, :before, :exception]`
    - `[:phoenix_gen_api, :hook, :after, :start]`
    - `[:phoenix_gen_api, :hook, :after, :stop]`
    - `[:phoenix_gen_api, :hook, :after, :exception]`

  ## Timeout

  Each hook execution is wrapped in a `Task` with a per-hook timeout
  (default: 5 seconds). If a hook does not complete within the timeout,
  the task is shut down and an error is returned. This prevents a
  misbehaving hook from blocking the request indefinitely.

  Hook crashes (exceptions) are also caught via `Task.yield/2` returning
  `{:exit, reason}`, and are reported the same way as before.

  ## Examples

      # In your FunConfig:
      %FunConfig{
        before_execute: {MyApp.Hooks, :validate_quota},
        after_execute: {MyApp.Hooks, :log_response}
      }

      # Hook module:
      defmodule MyApp.Hooks do
  alias PhoenixGenApi.Structs.{FunConfig, Request}

        def validate_quota(request, fun_config) do
          # Check rate quota, enrich request, etc.
          {:ok, request, fun_config}
        end

        def log_response(request, fun_config, result) do
          # Log metrics, audit trail, etc.
          result
        end
      end
  """

  alias PhoenixGenApi.Structs.{FunConfig, Request}

  alias PhoenixGenApi.LogContext

  require Logger

  @default_hook_timeout 5_000

  @doc """
  Runs the before_execute hook if configured.

  Returns `{:ok, request, fun_config}` to proceed, or `{:error, reason}` to abort.
  """
  @spec run_before(
          nil | {module(), atom()} | {module(), atom(), list()},
          Request.t(),
          FunConfig.t()
        ) :: {:ok, Request.t(), FunConfig.t()} | {:error, any()}
  def run_before(nil, request, fun_config), do: {:ok, request, fun_config}

  def run_before({mod, fun}, request, fun_config) do
    case execute_hook(:before, mod, fun, [request, fun_config], hook_timeout(fun_config)) do
      {:ok, {:ok, new_request, new_fun_config}} ->
        {:ok, new_request, new_fun_config}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, _} ->
        {:ok, request, fun_config}

      {:error, reason, _kind, _stacktrace} ->
        {:error, reason}
    end
  end

  def run_before({mod, fun, extra_args}, request, fun_config) do
    case execute_hook(
           :before,
           mod,
           fun,
           [request, fun_config | extra_args],
           hook_timeout(fun_config)
         ) do
      {:ok, {:ok, new_request, new_fun_config}} ->
        {:ok, new_request, new_fun_config}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, _} ->
        {:ok, request, fun_config}

      {:error, reason, _kind, _stacktrace} ->
        {:error, reason}
    end
  end

  @doc """
  Runs the after_execute hook if configured.

  Returns the (possibly modified) result. If the hook fails, the original result
  is preserved.
  """
  @spec run_after(
          nil | {module(), atom()} | {module(), atom(), list()},
          Request.t(),
          FunConfig.t(),
          any()
        ) :: any()
  def run_after(nil, _request, _fun_config, result), do: result

  def run_after({mod, fun}, request, fun_config, result) do
    case run_after_tagged({mod, fun}, request, fun_config, result) do
      {:ok, new_result} -> new_result
      {:error, _reason} -> result
    end
  end

  def run_after({mod, fun, extra_args}, request, fun_config, result) do
    case run_after_tagged({mod, fun, extra_args}, request, fun_config, result) do
      {:ok, new_result} -> new_result
      {:error, _reason} -> result
    end
  end

  @doc """
  Runs the after_execute hook and reports whether it succeeded.

  Returns `{:ok, result}` with the hook's (possibly modified) result, or
  `{:error, %{kind: kind, reason: reason, stacktrace: stacktrace}}` when the
  hook failed or timed out. Unlike `run_after/4`, a hook that returns the
  original result unchanged is still a success.
  """
  @spec run_after_tagged(
          nil | {module(), atom()} | {module(), atom(), list()},
          Request.t(),
          FunConfig.t(),
          any()
        ) :: {:ok, any()} | {:error, map()}
  def run_after_tagged(nil, _request, _fun_config, result), do: {:ok, result}

  def run_after_tagged({mod, fun}, request, fun_config, result) do
    execute_hook(:after, mod, fun, [request, fun_config, result], hook_timeout(fun_config))
    |> tag_result()
  end

  def run_after_tagged({mod, fun, extra_args}, request, fun_config, result) do
    execute_hook(
      :after,
      mod,
      fun,
      [request, fun_config, result | extra_args],
      hook_timeout(fun_config)
    )
    |> tag_result()
  end

  defp tag_result({:ok, hook_result}), do: {:ok, hook_result}

  defp tag_result({:error, reason, kind, stacktrace}) do
    {:error, %{kind: kind, reason: reason, stacktrace: stacktrace}}
  end

  defp hook_timeout(%FunConfig{hook_timeout: timeout}) when is_integer(timeout) and timeout > 0,
    do: timeout

  defp hook_timeout(_), do: @default_hook_timeout

  defp execute_hook(type, mod, fun, args, timeout) do
    start_time = System.monotonic_time(:microsecond)

    :telemetry.execute(
      [:phoenix_gen_api, :hook, type, :start],
      %{system_time: System.system_time()},
      %{module: mod, function: fun, type: type}
    )

    task =
      Task.async(fn ->
        try do
          {:__hook_ok__, apply(mod, fun, args)}
        rescue
          e -> {:__hook_exception__, :error, e, __STACKTRACE__}
        catch
          kind, value -> {:__hook_exception__, kind, value, __STACKTRACE__}
        end
      end)

    result =
      case Task.yield(task, timeout) do
        {:ok, {:__hook_ok__, hook_result}} ->
          {:ok, hook_result}

        {:ok, {:__hook_exception__, kind, reason, stacktrace}} ->
          {:error, reason, kind, stacktrace}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, "hook timed out after #{timeout}ms", :timeout, nil}

        {:exit, reason} ->
          {:error, reason, :exit, nil}
      end

    duration = System.monotonic_time(:microsecond) - start_time

    case result do
      {:ok, hook_result} ->
        :telemetry.execute(
          [:phoenix_gen_api, :hook, type, :stop],
          %{duration_us: duration},
          %{module: mod, function: fun, type: type}
        )

        {:ok, hook_result}

      {:error, reason, :timeout, _stacktrace} ->
        :telemetry.execute(
          [:phoenix_gen_api, :hook, type, :exception],
          %{duration_us: duration},
          %{
            module: mod,
            function: fun,
            type: type,
            kind: :timeout,
            reason: inspect(reason),
            stacktrace: nil
          }
        )

        Logger.error(
          LogContext.line(
            "Hooks",
            :hook_timeout,
            "#{type} hook timed out",
            LogContext.current(
              hook_type: type,
              hook: {mod, fun},
              timeout_ms: timeout
            )
          )
        )

        {:error, reason, :timeout, nil}

      {:error, reason, kind, stacktrace} ->
        :telemetry.execute(
          [:phoenix_gen_api, :hook, type, :exception],
          %{duration_us: duration},
          %{
            module: mod,
            function: fun,
            type: type,
            kind: kind,
            reason: inspect(reason),
            stacktrace: stacktrace
          }
        )

        Logger.error(
          LogContext.line(
            "Hooks",
            :hook_crashed,
            "#{type} hook crashed",
            LogContext.current(hook_type: type, hook: {mod, fun}, reason: reason, kind: kind)
          )
        )

        {:error, inspect(reason), kind, stacktrace}
    end
  end
end
