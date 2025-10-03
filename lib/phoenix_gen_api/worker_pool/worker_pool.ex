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

  ## Configuration

  Configure pool sizes in your `config.exs`:

      config :phoenix_gen_api, :worker_pool,
        async_pool_size: 100,
        stream_pool_size: 50,
        max_queue_size: 1000

  ## Usage

      # Execute a task asynchronously
      WorkerPool.execute_async(:async_pool, fn ->
        # Your async work here
        result = do_work()
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

  ## Supervision

  Workers are supervised and automatically restarted on failure. Failed tasks
  are not retried automatically - the caller should handle failures.
  """

  use GenServer

  require Logger

  @type pool_name :: :async_pool | :stream_pool
  @type task :: (-> any())

  defmodule State do
    @moduledoc false
    defstruct [
      :pool_name,
      :workers,
      :queue,
      :max_queue_size
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
  """
  @spec status(pool_name()) :: map()
  def status(pool_name) do
    GenServer.call(pool_name, :status)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    pool_name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, 10)
    max_queue_size = Keyword.get(opts, :max_queue_size, 1000)

    # Start worker processes
    workers =
      for _i <- 1..pool_size do
        {:ok, pid} = PhoenixGenApi.WorkerPool.Worker.start_link(pool_name: pool_name)
        {pid, :idle}
      end
      |> Map.new()

    state = %State{
      pool_name: pool_name,
      workers: workers,
      queue: :queue.new(),
      max_queue_size: max_queue_size
    }

    Logger.info(
      "WorkerPool started: #{pool_name}, size: #{pool_size}, max_queue: #{max_queue_size}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, task}, _from, state) do
    case find_idle_worker(state.workers) do
      {:ok, worker_pid} ->
        # Execute immediately on idle worker
        PhoenixGenApi.WorkerPool.Worker.execute(worker_pid, task)
        new_workers = Map.put(state.workers, worker_pid, :busy)
        {:reply, :ok, %{state | workers: new_workers}}

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

  @impl true
  def handle_call(:status, _from, state) do
    idle_count = Enum.count(state.workers, fn {_pid, status} -> status == :idle end)
    busy_count = Enum.count(state.workers, fn {_pid, status} -> status == :busy end)
    queued = :queue.len(state.queue)

    status = %{
      idle_workers: idle_count,
      busy_workers: busy_count,
      queued_tasks: queued
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:worker_done, worker_pid}, state) do
    # Mark worker as idle
    new_workers = Map.put(state.workers, worker_pid, :idle)

    # Try to execute queued task
    case :queue.out(state.queue) do
      {{:value, task}, new_queue} ->
        # Execute queued task on the now-idle worker
        PhoenixGenApi.WorkerPool.Worker.execute(worker_pid, task)
        final_workers = Map.put(new_workers, worker_pid, :busy)
        {:noreply, %{state | workers: final_workers, queue: new_queue}}

      {:empty, _queue} ->
        # No queued tasks, keep worker idle
        {:noreply, %{state | workers: new_workers}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, worker_pid, reason}, state) do
    Logger.warning(
      "WorkerPool #{state.pool_name}: worker #{inspect(worker_pid)} died: #{inspect(reason)}"
    )

    # Remove dead worker and start a new one
    new_workers = Map.delete(state.workers, worker_pid)
    {:ok, new_pid} = PhoenixGenApi.WorkerPool.Worker.start_link(pool_name: state.pool_name)
    final_workers = Map.put(new_workers, new_pid, :idle)

    {:noreply, %{state | workers: final_workers}}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unknown messages (e.g., from test helpers)
    {:noreply, state}
  end

  ## Private Functions

  defp find_idle_worker(workers) do
    case Enum.find(workers, fn {_pid, status} -> status == :idle end) do
      {pid, :idle} -> {:ok, pid}
      nil -> :no_idle_worker
    end
  end
end
