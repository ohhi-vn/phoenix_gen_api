defmodule PhoenixGenApi.WorkerPool.HardeningTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.WorkerPool

  defp start_pool(opts) do
    name = :"hardening_pool_#{System.unique_integer([:positive])}"
    {:ok, pid} = WorkerPool.start_link([name: name] ++ opts)

    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end)

    {name, pid}
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  test "one completion dispatches at most one queued task" do
    {pool, _pid} = start_pool(pool_size: 1, max_queue_size: 10)
    parent = self()

    first = fn ->
      send(parent, {:started, 1})
      send(parent, {:task_pid, self()})

      receive do
        :go -> :ok
      after
        2_000 -> :ok
      end
    end

    :ok = WorkerPool.execute_async(pool, first)
    assert_receive {:started, 1}
    assert_receive {:task_pid, first_pid}

    :ok = WorkerPool.execute_async(pool, fn -> send(parent, {:started, 2}) end)
    :ok = WorkerPool.execute_async(pool, fn -> send(parent, {:started, 3}) end)

    # The pool has one worker and it is still busy: nothing else may start.
    refute_receive {:started, 2}, 100
    refute_receive {:started, 3}, 0

    send(first_pid, :go)

    assert_receive {:started, 2}, 1_000
    assert_receive {:started, 3}, 1_000
  end

  test "concurrency never exceeds the pool size" do
    {pool, _pid} = start_pool(pool_size: 2, max_queue_size: 20)
    {:ok, agent} = Agent.start_link(fn -> %{current: 0, max: 0} end)

    task = fn ->
      Agent.update(agent, fn state ->
        current = state.current + 1
        %{state | current: current, max: max(state.max, current)}
      end)

      Process.sleep(30)

      Agent.update(agent, fn state -> %{state | current: state.current - 1} end)
    end

    for _ <- 1..8 do
      :ok = WorkerPool.execute_async(pool, task)
    end

    wait_until(fn -> Agent.get(agent, & &1.max) == 2 end, 100)
    wait_until(fn -> Agent.get(agent, & &1.current) == 0 end, 100)

    assert Agent.get(agent, & &1.max) == 2
  end

  test "a worker crash keeps the pool and its queue alive" do
    {pool, pool_pid} = start_pool(pool_size: 1, max_queue_size: 10)
    parent = self()

    blocker = fn ->
      send(parent, :blocked)

      receive do
        :never -> :ok
      after
        500 -> :ok
      end
    end

    :ok = WorkerPool.execute_async(pool, blocker)
    assert_receive :blocked

    :ok = WorkerPool.execute_async(pool, fn -> send(parent, :queued_ran) end)

    [worker_pid] = :sys.get_state(pool_pid).workers |> Map.keys()
    Process.exit(worker_pid, :kill)

    assert_receive :queued_ran, 2_000
    assert Process.alive?(pool_pid)
  end

  test "worker replacement emits a restart event" do
    parent = self()

    :telemetry.attach(
      "hardening-worker-restart",
      [:phoenix_gen_api, :worker_pool, :worker, :restart],
      fn _event, _measurements, metadata, _config ->
        send(parent, {:worker_restart, metadata})
      end,
      %{}
    )

    on_exit(fn -> :telemetry.detach("hardening-worker-restart") end)

    {pool, pool_pid} = start_pool(pool_size: 1, max_queue_size: 5)
    [worker_pid] = :sys.get_state(pool_pid).workers |> Map.keys()
    Process.exit(worker_pid, :kill)

    assert_receive {:worker_restart, %{pool_name: ^pool}}, 2_000
  end

  test "a circuit-open worker requeues instead of dropping the task" do
    original = Application.get_env(:phoenix_gen_api, :worker_pool)

    Application.put_env(:phoenix_gen_api, :worker_pool,
      circuit_breaker_threshold: 1,
      circuit_breaker_cooldown: 150
    )

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_gen_api, :worker_pool, original),
        else: Application.delete_env(:phoenix_gen_api, :worker_pool)
    end)

    {pool, _pid} = start_pool(pool_size: 1, max_queue_size: 10)
    parent = self()

    :ok =
      WorkerPool.execute_async(pool, fn ->
        send(parent, :failed_task_started)
        raise "boom"
      end)

    assert_receive :failed_task_started

    :ok = WorkerPool.execute_async(pool, fn -> send(parent, :second_ran) end)

    # The worker circuit is open right after the failure, so the task is
    # rejected and requeued — it must run after the cooldown, not vanish.
    refute_receive :second_ran, 50
    assert_receive :second_ran, 2_000
  end

  test "task timers are cancelled on completion" do
    {pool, pool_pid} = start_pool(pool_size: 1, max_queue_size: 5, task_timeout: 30_000)
    parent = self()

    :ok = WorkerPool.execute_async(pool, fn -> send(parent, :done) end)
    assert_receive :done

    wait_until(fn -> WorkerPool.status(pool).idle_workers == 1 end)

    [worker_pid] = :sys.get_state(pool_pid).workers |> Map.keys()
    assert :sys.get_state(worker_pid).timer_ref == nil
  end

  test "status reports failures and excludes dead workers" do
    {pool, pool_pid} = start_pool(pool_size: 2, max_queue_size: 5)
    parent = self()

    :ok =
      WorkerPool.execute_async(pool, fn ->
        send(parent, :ran)
        raise "boom"
      end)

    assert_receive :ran

    wait_until(fn -> WorkerPool.status(pool).total_tasks_failed == 1 end)

    status = WorkerPool.status(pool)
    assert status.total_tasks_failed == 1
    assert status.idle_workers + status.busy_workers == 2

    [worker_pid | _] = :sys.get_state(pool_pid).workers |> Map.keys()
    Process.exit(worker_pid, :kill)

    wait_until(fn ->
      state = :sys.get_state(pool_pid)
      not Map.has_key?(state.workers, worker_pid) and map_size(state.workers) == 2
    end)

    assert WorkerPool.status(pool).idle_workers + WorkerPool.status(pool).busy_workers == 2
  end
end
