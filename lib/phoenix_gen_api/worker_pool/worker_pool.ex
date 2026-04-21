defmodule PhoenixGenApi.WorkerPool do
  @moduledoc """
  Generic worker pool for executing tasks asynchronously.

  This module provides a pooling mechanism for executing async and stream tasks
  without spawning unlimited processes. Workers are supervised and reused across
  multiple requests.

  ## Architecture

  The worker pool consists of:
  - A pool of worker processes (GenServers)
  - A queue for pending tasks when all workers are busy
  - A supervisor managing the worker processes
  - Pool-level circuit breaker for fault tolerance

  ## Configuration

  Configure pool sizes in your `config.exs`:

      config :phoenix_gen_api, :worker_pool,
        async_pool_size: 100,
        stream_pool_size: 50,
        max_queue_size: 1000,
        task_timeout: 30_000

  ## Usage

      # Execute a task asynchronously
      WorkerPool.execute_async(:async_pool, fn ->
        # Your async work here
        result = process_data()
        send(caller_pid, {:result, result})
      end)

      # Execute a stream task
      WorkerPool.execute_async(:stream_pool, fn ->
        # Your stream work here
        StreamCall.handle_stream(request, config)
      end)

  ## Worker States

  Each worker can be in one of two states:
  - `:idle` - Available to accept new work
  - `:busy` - Currently executing a task

  ## Queue Management

  When all workers are busy, tasks are queued. If the queue exceeds the max size,
  new tasks will be rejected to prevent memory exhaustion.

  ## Circuit Breaker

  The pool tracks consecutive failures across all workers. If the failure rate
  exceeds the threshold, the pool enters a degraded state and rejects new tasks
  for a cooldown period.

  ## Supervision

  Workers are supervised and automatically restarted on failure. Failed tasks
  are not retried automatically - the caller should handle failures.
  """

  use GenServer

  require Logger

  @type pool_name :: :async_pool | :stream_pool
  @type task :: (-> any())

  @default_pool_size 10
  @default_max_queue_size 1000
  @default_task_timeout 30_000
  @circuit_breaker_threshold 10
  @circuit_breaker_cooldown 60_000

  defmodule State do
    @moduledoc false
    defstruct [
      :pool_name,
      :workers,
      :idle_workers,
      :queue,
      :max_queue_size,
      :task_timeout,
      consecutive_failures: 0,
      circuit_open_at: nil,
      total_tasks_executed: 0,
      total_tasks_failed: 0
    ]
  end

  ## Client API

  @doc """
  Starts the worker pool.

  ## Parameters

    - `opts` - Keyword list with:
      - `:name` - The pool name (required)
      - `:pool_size` - Number of workers (default: 10)
      - `:max_queue_size` - Maximum queued tasks (default: 1000)
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes a task asynchronously using the specified pool.

  ## Parameters

    - `pool_name` - The name of the worker pool
    - `task` - A zero-arity function to execute

  ## Returns

    - `:ok` - Task was accepted (either started or queued)
    - `{:error, :queue_full}` - Queue is at maximum capacity

  ## Examples

      WorkerPool.execute_async(:async_pool, fn ->
        # Do async work
        process_data()
      end)
  """
  @spec execute_async(pool_name(), task()) :: :ok | {:error, :queue_full}
  def execute_async(pool_name, task) when is_function(task, 0) do
    GenServer.call(pool_name, {:execute, task})
  end

  @doc """
  Gets the current status of the worker pool.

  ## Returns

  A map containing:
    - `:idle_workers` - Number of idle workers
    - `:busy_workers` - Number of busy workers
    - `:queued_tasks` - Number of tasks in queue
    - `:circuit_open` - Whether circuit breaker is open
    - `:total_tasks_executed` - Total tasks executed since start
    - `:total_tasks_failed` - Total tasks failed since start
  """
  @spec status(pool_name()) :: map()
  def status(pool_name) do
    GenServer.call(pool_name, :status)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    pool_name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, @default_pool_size)
    max_queue_size = Keyword.get(opts, :max_queue_size, @default_max_queue_size)
    task_timeout = Keyword.get(opts, :task_timeout, @default_task_timeout)

    # Start worker processes and track idle workers in a set for O(1) lookup
    {workers, idle_workers} =
      for _i <- 1..pool_size, reduce: {%{}, MapSet.new()} do
        {workers_acc, idle_acc} ->
          {:ok, pid} =
            PhoenixGenApi.WorkerPool.Worker.start_link(
              pool_name: pool_name,
              task_timeout: task_timeout
            )

          Process.monitor(pid)
          {Map.put(workers_acc, pid, :idle), MapSet.put(idle_acc, pid)}
      end

    state = %State{
      pool_name: pool_name,
      workers: workers,
      idle_workers: idle_workers,
      queue: :queue.new(),
      max_queue_size: max_queue_size,
      task_timeout: task_timeout
    }

    Logger.info(
      "WorkerPool started: #{pool_name}, size: #{pool_size}, max_queue: #{max_queue_size}, task_timeout: #{task_timeout}ms"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, task}, _from, state) do
    # Check pool-level circuit breaker
    if circuit_open?(state) do
      Logger.warning("WorkerPool #{state.pool_name}: circuit breaker open, rejecting task")

      {:reply, {:error, :circuit_open}, state}
    else
      case find_idle_worker(state.idle_workers) do
        {:ok, worker_pid} ->
          # Execute immediately on idle worker
          PhoenixGenApi.WorkerPool.Worker.execute(worker_pid, task)
          new_workers = Map.put(state.workers, worker_pid, :busy)
          new_idle = MapSet.delete(state.idle_workers, worker_pid)
          {:reply, :ok, %{state | workers: new_workers, idle_workers: new_idle}}

        :no_idle_worker ->
          # Queue the task if under limit
          queue_size = :queue.len(state.queue)

          if queue_size >= state.max_queue_size do
            Logger.warning("WorkerPool #{state.pool_name}: queue full, rejecting task")
            {:reply, {:error, :queue_full}, state}
          else
            new_queue = :queue.in(task, state.queue)
            {:reply, :ok, %{state | queue: new_queue}}
          end
      end
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    idle_count = MapSet.size(state.idle_workers)
    busy_count = map_size(state.workers) - idle_count
    queued = :queue.len(state.queue)

    status = %{
      idle_workers: idle_count,
      busy_workers: busy_count,
      queued_tasks: queued,
      circuit_open: circuit_open?(state),
      total_tasks_executed: state.total_tasks_executed,
      total_tasks_failed: state.total_tasks_failed
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:worker_done, worker_pid}, state) do
    # Mark worker as idle
    new_workers = Map.put(state.workers, worker_pid, :idle)
    new_idle = MapSet.put(state.idle_workers, worker_pid)

    # Try to execute queued task
    case :queue.out(state.queue) do
      {{:value, task}, new_queue} ->
        # Execute queued task on the now-idle worker
        PhoenixGenApi.WorkerPool.Worker.execute(worker_pid, task)
        final_workers = Map.put(new_workers, worker_pid, :busy)
        final_idle = MapSet.delete(new_idle, worker_pid)

        new_state =
          record_success(%{
            state
            | workers: final_workers,
              idle_workers: final_idle,
              queue: new_queue
          })

        {:noreply, new_state}

      {:empty, _queue} ->
        # No queued tasks, keep worker idle
        new_state = record_success(%{state | workers: new_workers, idle_workers: new_idle})
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, worker_pid, reason}, state) do
    Logger.warning(
      "WorkerPool #{state.pool_name}: worker #{inspect(worker_pid)} died: #{inspect(reason)}"
    )

    # Remove dead worker and start a new one
    new_workers = Map.delete(state.workers, worker_pid)
    new_idle = MapSet.delete(state.idle_workers, worker_pid)

    {:ok, new_pid} =
      PhoenixGenApi.WorkerPool.Worker.start_link(
        pool_name: state.pool_name,
        task_timeout: state.task_timeout
      )

    Process.monitor(new_pid)
    final_workers = Map.put(new_workers, new_pid, :idle)
    final_idle = MapSet.put(new_idle, new_pid)

    # Record failure for circuit breaker
    new_state = record_failure(%{state | workers: final_workers, idle_workers: final_idle})

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unknown messages (e.g., from test helpers)
    {:noreply, state}
  end

  ## Private Functions

  defp find_idle_worker(idle_workers) do
    case MapSet.to_list(idle_workers) do
      [pid | _] -> {:ok, pid}
      [] -> :no_idle_worker
    end
  end

  defp circuit_open?(%State{circuit_open_at: nil}), do: false

  defp circuit_open?(%State{circuit_open_at: opened_at}) do
    if System.monotonic_time(:millisecond) - opened_at < @circuit_breaker_cooldown do
      true
    else
      # Cooldown period has passed, reset circuit breaker
      false
    end
  end

  defp record_failure(state) do
    new_failures = state.consecutive_failures + 1
    new_total_failed = state.total_tasks_failed + 1

    if new_failures >= @circuit_breaker_threshold and state.circuit_open_at == nil do
      Logger.warning(
        "WorkerPool #{state.pool_name}: circuit breaker opened after #{new_failures} consecutive failures"
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
          circuit_open_at: System.monotonic_time(:millisecond),
          total_tasks_failed: new_total_failed
      }
    else
      %{state | consecutive_failures: new_failures, total_tasks_failed: new_total_failed}
    end
  end

  defp record_success(state) do
    if state.consecutive_failures > 0 do
      Logger.info(
        "WorkerPool #{state.pool_name}: circuit breaker reset after successful task execution"
      )

      :telemetry.execute(
        [:phoenix_gen_api, :worker_pool, :circuit_breaker, :close],
        %{},
        %{pool_name: state.pool_name}
      )
    end

    %{
      state
      | consecutive_failures: 0,
        circuit_open_at: nil,
        total_tasks_executed: state.total_tasks_executed + 1
    }
  end
end
