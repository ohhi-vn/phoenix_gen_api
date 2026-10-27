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
        async_pool_size: 1000,
        stream_pool_size: 500,
        max_queue_size: 10_000,
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

  ## Circuit Breaker Configuration

  Configure circuit breaker behavior in your `config.exs`:

      config :phoenix_gen_api, :worker_pool,
        circuit_breaker_threshold: 10,
        circuit_breaker_cooldown: 60_000

  - `circuit_breaker_threshold` - Number of consecutive failures before the circuit opens (default: 10 for pool, 5 for worker).
  - `circuit_breaker_cooldown` - Cooldown period in milliseconds before the circuit closes (default: 60000).

  ## Supervision

  Workers are supervised and automatically restarted on failure. Failed tasks
  are not retried automatically - the caller should handle failures.
  """

  use GenServer

  alias PhoenixGenApi.WorkerPool.CircuitBreaker
  alias PhoenixGenApi.WorkerPool.Worker

  alias PhoenixGenApi.LogContext

  require Logger

  @type pool_name :: :async_pool | :stream_pool
  @type task :: (-> any())

  @default_pool_size 10
  @default_max_queue_size 10_000
  @default_task_timeout 30_000
  @respawn_delay_ms 1_000

  defmodule State do
    @moduledoc false
    defstruct [
      :pool_name,
      :workers,
      :idle_workers,
      # Cache list for O(1) access
      :idle_workers_list,
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
      - `:pool_size` - Number of workers (default: depends on pool type)
      - `:max_queue_size` - Maximum queued tasks (default: 10_000)
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

    # Workers are linked; trap exits so a worker crash is handled as a
    # replaceable event instead of tearing down the pool (and its queue).
    Process.flag(:trap_exit, true)

    # Start worker processes and track idle workers in a set for O(1) lookup
    {workers, idle_workers, idle_list} =
      for _i <- 1..pool_size, reduce: {%{}, MapSet.new(), []} do
        {workers_acc, idle_acc, list_acc} ->
          {:ok, pid} =
            Worker.start_link(
              pool_name: pool_name,
              task_timeout: task_timeout
            )

          Process.monitor(pid)
          {Map.put(workers_acc, pid, :idle), MapSet.put(idle_acc, pid), [pid | list_acc]}
      end

    state = %State{
      pool_name: pool_name,
      workers: workers,
      idle_workers: idle_workers,
      idle_workers_list: idle_list,
      queue: :queue.new(),
      max_queue_size: max_queue_size,
      task_timeout: task_timeout
    }

    Logger.info(
      LogContext.line("WorkerPool", :started, "started",
        pool: pool_name,
        size: pool_size,
        max_queue: max_queue_size,
        task_timeout_ms: task_timeout,
        node: node()
      )
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    idle_count = MapSet.size(state.idle_workers)

    busy_count =
      Enum.count(state.workers, fn {_pid, worker_state} -> worker_state in [:busy, :paused] end)

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
  def handle_call({:execute, task}, _from, state) do
    # Check pool-level circuit breaker
    if circuit_open?(state) do
      Logger.warning(
        LogContext.line(
          "WorkerPool",
          :circuit_breaker_open,
          "circuit breaker open, rejecting task",
          pool: state.pool_name,
          node: node()
        )
      )

      {:reply, {:error, :circuit_open}, state}
    else
      case take_idle_worker(state) do
        {:ok, worker_pid, state} ->
          Worker.execute(worker_pid, task)
          {:reply, :ok, state}

        :none ->
          queue_task(task, state)
      end
    end
  end

  defp take_idle_worker(state) do
    case state.idle_workers_list do
      [worker_pid | rest] ->
        if MapSet.member?(state.idle_workers, worker_pid) do
          {:ok, worker_pid,
           %{
             state
             | idle_workers_list: rest,
               idle_workers: MapSet.delete(state.idle_workers, worker_pid),
               workers: Map.put(state.workers, worker_pid, :busy)
           }}
        else
          # Stale entry (worker went away); drop it and continue.
          take_idle_worker(%{state | idle_workers_list: rest})
        end

      [] ->
        :none
    end
  end

  defp mark_idle(state, worker_pid) do
    %{
      state
      | workers: Map.put(state.workers, worker_pid, :idle),
        idle_workers: MapSet.put(state.idle_workers, worker_pid),
        idle_workers_list: [worker_pid | List.delete(state.idle_workers_list, worker_pid)]
    }
  end

  defp queue_task(task, state) do
    queue_size = :queue.len(state.queue)

    if queue_size >= state.max_queue_size do
      Logger.warning(
        LogContext.line("WorkerPool", :queue_full, "queue full, rejecting task",
          pool: state.pool_name,
          max_queue: state.max_queue_size,
          node: node()
        )
      )

      {:reply, {:error, :queue_full}, state}
    else
      new_queue = :queue.in(task, state.queue)
      {:reply, :ok, %{state | queue: new_queue}}
    end
  end

  @impl true
  def handle_info({:worker_done, worker_pid}, state) do
    handle_worker_done(worker_pid, :ok, state)
  end

  @impl true
  def handle_info({:worker_done, worker_pid, outcome}, state)
      when outcome in [:ok, :error] do
    handle_worker_done(worker_pid, outcome, state)
  end

  @impl true
  def handle_info({:worker_rejected, worker_pid, _reason, task}, state) do
    if Map.has_key?(state.workers, worker_pid) do
      cooldown = circuit_breaker_cooldown()

      Logger.warning(
        LogContext.line(
          "WorkerPool",
          :worker_circuit_open,
          "worker circuit open, requeueing task",
          pool: state.pool_name,
          worker_pid: worker_pid,
          cooldown_ms: cooldown,
          node: node()
        )
      )

      Process.send_after(self(), {:resume_worker, worker_pid}, cooldown)

      new_state = %{
        state
        | workers: Map.put(state.workers, worker_pid, :paused),
          idle_workers: MapSet.delete(state.idle_workers, worker_pid),
          idle_workers_list: List.delete(state.idle_workers_list, worker_pid),
          queue: :queue.in_r(task, state.queue)
      }

      {:noreply, dispatch_next(new_state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:resume_worker, worker_pid}, state) do
    case Map.get(state.workers, worker_pid) do
      :paused ->
        if Process.alive?(worker_pid) do
          {:noreply, dispatch_next(mark_idle(state, worker_pid))}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:respawn_worker, state) do
    {:noreply, start_replacement_worker(state, :respawn)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, worker_pid, reason}, state) do
    handle_worker_down(worker_pid, reason, state)
  end

  @impl true
  def handle_info({:EXIT, worker_pid, reason}, state) do
    if Map.has_key?(state.workers, worker_pid) do
      handle_worker_down(worker_pid, reason, state)
    else
      # Exit from a linked process that is not a worker (e.g. the supervisor).
      {:stop, reason, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp handle_worker_done(worker_pid, outcome, state) do
    cond do
      not Map.has_key?(state.workers, worker_pid) ->
        # Stale completion for a worker that was already replaced.
        {:noreply, state}

      MapSet.member?(state.idle_workers, worker_pid) ->
        # Duplicate completion for a worker that is already idle.
        {:noreply, state}

      Map.get(state.workers, worker_pid) == :paused ->
        {:noreply, state}

      true ->
        new_state =
          state
          |> record_outcome(outcome)
          |> mark_idle(worker_pid)
          |> dispatch_next()

        {:noreply, new_state}
    end
  end

  defp handle_worker_down(worker_pid, reason, state) do
    if Map.has_key?(state.workers, worker_pid) do
      Logger.warning(
        LogContext.line("WorkerPool", :worker_died, "worker died, restarting worker",
          pool: state.pool_name,
          worker_pid: worker_pid,
          reason: reason,
          node: node()
        )
      )

      new_state = %{
        state
        | workers: Map.delete(state.workers, worker_pid),
          idle_workers: MapSet.delete(state.idle_workers, worker_pid),
          idle_workers_list: List.delete(state.idle_workers_list, worker_pid),
          consecutive_failures: 0
      }

      {:noreply, start_replacement_worker(new_state, reason)}
    else
      {:noreply, state}
    end
  end

  defp start_replacement_worker(state, reason) do
    case Worker.start_link(pool_name: state.pool_name, task_timeout: state.task_timeout) do
      {:ok, new_pid} ->
        Process.monitor(new_pid)

        :telemetry.execute(
          [:phoenix_gen_api, :worker_pool, :worker, :restart],
          %{},
          %{pool_name: state.pool_name, reason: reason}
        )

        state
        |> mark_idle(new_pid)
        |> dispatch_next()

      {:error, start_reason} ->
        Logger.error(
          LogContext.line(
            "WorkerPool",
            :worker_restart_failed,
            "worker restart failed, retrying",
            pool: state.pool_name,
            reason: start_reason,
            node: node()
          )
        )

        Process.send_after(self(), :respawn_worker, @respawn_delay_ms)
        state
    end
  end

  defp dispatch_next(state) do
    case :queue.out(state.queue) do
      {{:value, task}, queue} ->
        case take_idle_worker(%{state | queue: queue}) do
          {:ok, worker_pid, new_state} ->
            Worker.execute(worker_pid, task)
            dispatch_next(new_state)

          :none ->
            state
        end

      {:empty, _queue} ->
        state
    end
  end

  ## Circuit Breaker Functions

  defp circuit_breaker_cooldown do
    Application.get_env(:phoenix_gen_api, :worker_pool, [])[:circuit_breaker_cooldown] || 60_000
  end

  defp circuit_open?(%State{circuit_open_at: nil}), do: false

  defp circuit_open?(%State{circuit_open_at: circuit_open_at}) do
    CircuitBreaker.circuit_open?(
      circuit_open_at,
      circuit_breaker_cooldown()
    )
  end

  defp record_outcome(state, :ok), do: record_success(state)

  defp record_outcome(state, :error) do
    %{
      state
      | total_tasks_failed: state.total_tasks_failed + 1,
        consecutive_failures: state.consecutive_failures + 1
    }
  end

  defp record_success(state) do
    if state.circuit_open_at != nil do
      Logger.info(
        LogContext.line(
          "WorkerPool",
          :circuit_breaker_reset,
          "circuit breaker reset after successful task execution",
          pool: state.pool_name,
          node: node()
        )
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
