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
        alias PhoenixGenApi.Structs.{Request, FunConfig}

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

  alias PhoenixGenApi.Structs.{Request, FunConfig}

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
    case execute_hook(:before, mod, fun, [request, fun_config]) do
      {:ok, {:ok, new_request, new_fun_config}} ->
        {:ok, new_request, new_fun_config}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, _} ->
        {:ok, request, fun_config}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_before({mod, fun, extra_args}, request, fun_config) do
    case execute_hook(:before, mod, fun, [request, fun_config | extra_args]) do
      {:ok, {:ok, new_request, new_fun_config}} ->
        {:ok, new_request, new_fun_config}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, _} ->
        {:ok, request, fun_config}

      {:error, reason} ->
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
    case execute_hook(:after, mod, fun, [request, fun_config, result]) do
      {:ok, new_result} -> new_result
      {:error, _} -> result
    end
  end

  def run_after({mod, fun, extra_args}, request, fun_config, result) do
    case execute_hook(:after, mod, fun, [request, fun_config, result | extra_args]) do
      {:ok, new_result} -> new_result
      {:error, _} -> result
    end
  end

  defp execute_hook(type, mod, fun, args) do
    start_time = System.monotonic_time(:microsecond)

    :telemetry.execute(
      [:phoenix_gen_api, :hook, type, :start],
      %{system_time: System.system_time()},
      %{module: mod, function: fun, type: type}
    )

    task = Task.async(fn ->
      try do
        apply(mod, fun, args)
      rescue
        e -> {:__hook_exception, Exception.message(e)}
      catch
        kind, value -> {:__hook_exception, {kind, value}}
      end
    end)

    result =
      case Task.yield(task, @default_hook_timeout) do
        {:ok, {:__hook_exception, reason}} ->
          {:exit, reason}

        {:ok, hook_result} ->
          {:ok, hook_result}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:timeout, "hook timed out after #{@default_hook_timeout}ms"}

        {:exit, reason} ->
          {:exit, reason}
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

      {:timeout, reason} ->
        :telemetry.execute(
          [:phoenix_gen_api, :hook, type, :exception],
          %{duration_us: duration},
          %{
            module: mod,
            function: fun,
            type: type,
            kind: :timeout,
            reason: reason,
            stacktrace: nil
          }
        )

        Logger.error(
          "[Hooks] #{type} hook timed out after #{@default_hook_timeout}ms, module: #{inspect(mod)}, function: #{inspect(fun)}"
        )

        {:error, reason}

      {:exit, reason} ->
        :telemetry.execute(
          [:phoenix_gen_api, :hook, type, :exception],
          %{duration_us: duration},
          %{
            module: mod,
            function: fun,
            type: type,
            kind: :error,
            reason: inspect(reason),
            stacktrace: nil
          }
        )

        Logger.error(
          "[Hooks] #{type} hook crashed: #{inspect(reason)}, module: #{inspect(mod)}, function: #{inspect(fun)}"
        )

        {:error, inspect(reason)}
    end
  end
end
