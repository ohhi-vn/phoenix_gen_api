defmodule PhoenixGenApi.WorkerPool.Worker do
  @moduledoc """
  Individual worker process for executing tasks.

  Workers are managed by the WorkerPool and execute tasks one at a time.
  When a task completes, the worker notifies the pool that it's available
  for more work.

  ## Lifecycle

  1. Worker starts in idle state
  2. Pool assigns a task via `execute/2`
  3. Worker executes the task
  4. Worker notifies pool when done
  5. Returns to idle state

  ## Error Handling

  If a task raises an exception, the worker catches it, logs the error,
  and continues running. The pool is notified that the worker is done
  even if the task failed.
  """

  use GenServer

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:pool_name, :current_task]
  end

  ## Client API

  @doc """
  Starts a worker process.

  ## Parameters

    - `opts` - Keyword list with:
      - `:pool_name` - Name of the parent pool (required)
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
    state = %State{pool_name: pool_name, current_task: nil}
    {:ok, state}
  end

  @impl true
  def handle_cast({:execute, task}, state) do
    # Execute task in a separate process to avoid blocking the worker
    parent = self()
    pool = state.pool_name

    spawn_link(fn ->
      try do
        task.()
      rescue
        error ->
          Logger.error(
            "WorkerPool.Worker: task failed: #{inspect(error)}\n#{Exception.format_stacktrace()}"
          )
      catch
        kind, value ->
          Logger.error("WorkerPool.Worker: task crashed: #{kind}: #{inspect(value)}")
      after
        # Always notify pool that worker is done
        send(pool, {:worker_done, parent})
      end
    end)

    {:noreply, %{state | current_task: task}}
  end

  @impl true
  def handle_info(_msg, state) do
    # Ignore unknown messages
    {:noreply, state}
  end
end
