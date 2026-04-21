defmodule PhoenixGenApi.WorkerPool.Worker do
  @moduledoc """
  Individual worker process for executing tasks.

  Workers are managed by the WorkerPool and execute tasks one at a time.
  When a task completes, the worker notifies the pool that it's available
  for more work.

  ## Lifecycle

  1. Worker starts in idle state
  2. Pool assigns a task via `execute/2`
  3. Worker executes the task with timeout protection
  4. Worker notifies pool when done
  5. Returns to idle state

  ## Error Handling

  If a task raises an exception, the worker catches it, logs the error,
  and continues running. The pool is notified that the worker is done
  even if the task failed.

  ## Circuit Breaker

  Workers track consecutive failures. If failures exceed the threshold,
  the worker enters a "circuit open" state and rejects new tasks for a
  cooldown period. This prevents cascading failures when downstream
  services are unhealthy.
  """

  use GenServer

  require Logger

  @default_task_timeout 30_000
  @circuit_breaker_threshold 5
  @circuit_breaker_cooldown 60_000

  defmodule State do
    @moduledoc false
    @default_task_timeout 30_000
    defstruct [
      :pool_name,
      :current_task,
      :current_task_pid,
      :task_start_time,
      task_exception: false,
      consecutive_failures: 0,
      circuit_open_at: nil,
      task_timeout: @default_task_timeout
    ]
  end

  ## Client API

  @doc """
  Starts a worker process.

  ## Parameters

    - `opts` - Keyword list with:
      - `:pool_name` - Name of the parent pool (required)
      - `:task_timeout` - Task execution timeout in milliseconds (default: 30000)
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Executes a task on this worker.

  ## Parameters

    - `worker_pid` - The worker process PID
    - `task` - A zero-arity function to execute
  """
  def execute(worker_pid, task) when is_function(task, 0) do
    GenServer.cast(worker_pid, {:execute, task})
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    pool_name = Keyword.fetch!(opts, :pool_name)
    task_timeout = Keyword.get(opts, :task_timeout, @default_task_timeout)

    state = %State{
      pool_name: pool_name,
      current_task: nil,
      task_timeout: task_timeout
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:execute, task}, state) do
    # Check circuit breaker state
    if circuit_open?(state) do
      Logger.warning(
        "WorkerPool.Worker: circuit breaker open, rejecting task for pool #{inspect(state.pool_name)}"
      )

      # Notify pool immediately that worker is done (task rejected)
      send(state.pool_name, {:worker_done, self()})
      {:noreply, state}
    else
      # Execute task in a separate process with timeout
      parent = self()
      pool = state.pool_name
      timeout = state.task_timeout
      start_time = System.monotonic_time(:microsecond)

      :telemetry.execute(
        [:phoenix_gen_api, :worker_pool, :task, :start],
        %{system_time: System.system_time()},
        %{pool_name: pool}
      )

      task_pid =
        spawn(fn ->
          try do
            task.()
          rescue
            error ->
              duration = System.monotonic_time(:microsecond) - start_time

              :telemetry.execute(
                [:phoenix_gen_api, :worker_pool, :task, :exception],
                %{duration_us: duration},
                %{
                  pool_name: pool,
                  kind: :error,
                  reason: Exception.message(error),
                  stacktrace: Exception.format_stacktrace(__STACKTRACE__)
                }
              )

              Logger.error(
                "WorkerPool.Worker: task failed: #{Exception.message(error)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
              )

              # Notify worker that task failed so it can record the failure
              send(parent, {:task_exception, self()})
          catch
            kind, value ->
              duration = System.monotonic_time(:microsecond) - start_time

              :telemetry.execute(
                [:phoenix_gen_api, :worker_pool, :task, :exception],
                %{duration_us: duration},
                %{
                  pool_name: pool,
                  kind: kind,
                  reason: inspect(value),
                  stacktrace: nil
                }
              )

              Logger.error("WorkerPool.Worker: task crashed: #{kind}: #{inspect(value)}")

              # Notify worker that task failed so it can record the failure
              send(parent, {:task_exception, self()})
          after
            # Always notify pool that worker is done
            send(pool, {:worker_done, parent})
          end
        end)

      # Monitor task for crash detection and timeout
      Process.monitor(task_pid)
      Process.send_after(self(), {:task_timeout, task_pid}, timeout)

      {:noreply,
       %{state | current_task: task, current_task_pid: task_pid, task_start_time: start_time}}
    end
  end

  @impl true
  def handle_info({:task_timeout, task_pid}, state) do
    if state.current_task_pid == task_pid and Process.alive?(task_pid) do
      Logger.error(
        "WorkerPool.Worker: task timed out after #{state.task_timeout}ms, terminating task"
      )

      duration = System.monotonic_time(:microsecond) - state.task_start_time

      :telemetry.execute(
        [:phoenix_gen_api, :worker_pool, :task, :exception],
        %{duration_us: duration},
        %{
          pool_name: state.pool_name,
          kind: :timeout,
          reason: "task timed out after #{state.task_timeout}ms",
          stacktrace: nil
        }
      )

      Process.exit(task_pid, :kill)
      new_state = record_failure(state)
      send(state.pool_name, {:worker_done, self()})
      {:noreply, %{new_state | current_task: nil, current_task_pid: nil, task_start_time: nil}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_exception, task_pid}, state) do
    if state.current_task_pid == task_pid do
      # Exception telemetry was already emitted from the spawned task process.
      # Record the failure and mark that we've already handled this exception
      # so the :DOWN handler doesn't emit duplicate telemetry.
      new_state = record_failure(state)
      {:noreply, %{new_state | task_exception: true}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, task_pid, reason}, state) do
    if state.current_task_pid == task_pid do
      duration = System.monotonic_time(:microsecond) - state.task_start_time

      new_state =
        cond do
          # Exception telemetry was already emitted from the spawned task process
          state.task_exception ->
            # Failure was already recorded in handle_info({:task_exception, ...})
            state

          reason != :normal and reason != :shutdown ->
            Logger.warning("WorkerPool.Worker: task process died: #{inspect(reason)}")

            :telemetry.execute(
              [:phoenix_gen_api, :worker_pool, :task, :exception],
              %{duration_us: duration},
              %{
                pool_name: state.pool_name,
                kind: :error,
                reason: inspect(reason),
                stacktrace: nil
              }
            )

            record_failure(state)

          true ->
            :telemetry.execute(
              [:phoenix_gen_api, :worker_pool, :task, :stop],
              %{duration_us: duration},
              %{pool_name: state.pool_name}
            )

            record_success(state)
        end

      send(state.pool_name, {:worker_done, self()})

      {:noreply,
       %{
         new_state
         | current_task: nil,
           current_task_pid: nil,
           task_start_time: nil,
           task_exception: false
       }}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:task_completed, task_pid}, state) do
    if state.current_task_pid == task_pid do
      duration = System.monotonic_time(:microsecond) - state.task_start_time

      :telemetry.execute(
        [:phoenix_gen_api, :worker_pool, :task, :stop],
        %{duration_us: duration},
        %{pool_name: state.pool_name}
      )

      new_state = record_success(state)

      {:noreply,
       %{
         new_state
         | current_task: nil,
           current_task_pid: nil,
           task_start_time: nil,
           task_exception: false
       }}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unknown messages
    {:noreply, state}
  end

  ## Circuit Breaker Functions

  defp circuit_open?(%State{circuit_open_at: nil}), do: false

  defp circuit_open?(%State{circuit_open_at: opened_at}) do
    if System.monotonic_time(:millisecond) - opened_at < @circuit_breaker_cooldown do
      true
    else
      # Cooldown period has passed, allow task execution
      false
    end
  end

  defp record_failure(state) do
    new_failures = state.consecutive_failures + 1

    if new_failures >= @circuit_breaker_threshold do
      Logger.warning(
        "WorkerPool.Worker: circuit breaker opened after #{new_failures} consecutive failures"
      )

      :telemetry.execute(
        [:phoenix_gen_api, :worker_pool, :circuit_breaker, :open],
        %{},
        %{
          pool_name: state.pool_name,
          consecutive_failures: new_failures
        }
      )

      %{
        state
        | consecutive_failures: new_failures,
          circuit_open_at: System.monotonic_time(:millisecond)
      }
    else
      %{state | consecutive_failures: new_failures}
    end
  end

  defp record_success(state) do
    if state.consecutive_failures > 0 do
      Logger.info("WorkerPool.Worker: circuit breaker reset after successful task execution")

      :telemetry.execute(
        [:phoenix_gen_api, :worker_pool, :circuit_breaker, :close],
        %{},
        %{pool_name: state.pool_name}
      )
    end

    %{state | consecutive_failures: 0, circuit_open_at: nil}
  end
end
