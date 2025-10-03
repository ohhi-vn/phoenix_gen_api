defmodule PhoenixGenApi.WorkerPoolTest do
  use ExUnit.Case, async: false

  alias PhoenixGenApi.WorkerPool

  setup do
    # Start a test worker pool
    {:ok, pool_pid} =
      start_supervised({WorkerPool, name: :test_pool, pool_size: 3, max_queue_size: 5})

    {:ok, pool_pid: pool_pid}
  end

  describe "execute_async/2" do
    test "executes task successfully" do
      parent = self()

      task = fn ->
        send(parent, :task_executed)
      end

      assert :ok = WorkerPool.execute_async(:test_pool, task)

      assert_receive :task_executed, 1000
    end

    test "executes multiple tasks concurrently" do
      parent = self()

      tasks =
        for i <- 1..5 do
          fn ->
            Process.sleep(10)
            send(parent, {:task_done, i})
          end
        end

      # Submit all tasks
      Enum.each(tasks, fn task ->
        assert :ok = WorkerPool.execute_async(:test_pool, task)
      end)

      # All tasks should complete
      for i <- 1..5 do
        assert_receive {:task_done, ^i}, 2000
      end
    end

    test "queues tasks when all workers are busy" do
      parent = self()
      latch = make_ref()

      pids = add_blocking_tasks_to_pool(parent, latch, 3)

      # Queue additional task
      queued_task = fn ->
        send(parent, :queued_task_done)
      end

      assert :ok = WorkerPool.execute_async(:test_pool, queued_task)

      # Verify task hasn't executed yet
      refute_receive :queued_task_done, 100

      # Release workers
      for _ <- 1..3 do
        send_to_all_workers(pids, latch)
      end

      # Queued task should now execute
      assert_receive :queued_task_done, 1000
    end

    test "returns error when queue is full" do
      parent = self()
      latch = make_ref()

      pids = add_blocking_tasks_to_pool(parent, latch, 3)

      # Fill the queue (max 5)
      simple_task = fn -> send(parent, :done) end

      for _ <- 1..5 do
        assert :ok = WorkerPool.execute_async(:test_pool, simple_task)
      end

      # Next task should fail
      assert {:error, :queue_full} = WorkerPool.execute_async(:test_pool, simple_task)

      # Release workers
      for _ <- 1..3 do
        send_to_all_workers(pids, latch)
      end
    end

    test "handles task failures gracefully" do
      parent = self()

      failing_task = fn ->
        raise "Task failed"
      end

      assert :ok = WorkerPool.execute_async(:test_pool, failing_task)

      # Worker should still be available for next task
      Process.sleep(100)

      success_task = fn ->
        send(parent, :success)
      end

      assert :ok = WorkerPool.execute_async(:test_pool, success_task)
      assert_receive :success, 1000
    end
  end

  describe "status/1" do
    test "reports correct status" do
      status = WorkerPool.status(:test_pool)

      assert status.idle_workers == 3
      assert status.busy_workers == 0
      assert status.queued_tasks == 0
    end

    test "reports status with busy workers" do
      latch = make_ref()
      parent = self()

      pids = add_blocking_tasks_to_pool(parent, latch, 2)

      Process.sleep(50)

      status = WorkerPool.status(:test_pool)

      assert status.idle_workers == 1
      assert status.busy_workers == 2
      assert status.queued_tasks == 0

      # Release workers
      send_to_all_workers(pids, latch)
    end

    test "reports status with queued tasks" do
      latch = make_ref()
      parent = self()

      pids = add_blocking_tasks_to_pool(parent, latch, 3)

      # Queue 2 tasks
      for _ <- 1..2 do
        WorkerPool.execute_async(:test_pool, fn -> :ok end)
      end

      Process.sleep(50)

      status = WorkerPool.status(:test_pool)

      assert status.idle_workers == 0
      assert status.busy_workers == 3
      assert status.queued_tasks == 2

      # Release workers
      send_to_all_workers(pids, latch)
    end
  end

  # Helper to send message to all worker processes (broadcast)
  defp send_to_all_workers(pids, message) do
    # Send to all processes - workers will receive the message in their task execution
    Enum.each(pids, fn pid ->
      # Only send to alive processes
      if Process.alive?(pid) do
        try do
          send(pid, message)
        catch
          _, _ -> :ok
        end
      end
    end)

    # Give time for messages to be processed
    Process.sleep(50)
  end

  defp add_blocking_tasks_to_pool(parent, latch, n) do
    # Fill all workers with blocking tasks
    blocking_task = fn ->
      Process.sleep(10)
      send(parent, {:my_pid, self()})

      receive do
        ^latch -> :ok
      end

      send(parent, :blocking_done)
    end

    # Fill the n workers
    for _ <- 1..n do
      assert :ok = WorkerPool.execute_async(:test_pool, blocking_task)
    end

    Enum.reduce(1..n, [], fn _, acc ->
      receive do
        {:my_pid, pid} -> [pid | acc]
      end
    end)
  end
end
