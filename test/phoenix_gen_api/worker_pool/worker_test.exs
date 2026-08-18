defmodule PhoenixGenApi.WorkerPool.WorkerTest do
  use ExUnit.Case, async: true

  alias PhoenixGenApi.WorkerPool.Worker

  describe "execute/2" do
    test "executes task and notifies pool when done" do
      parent = self()

      {:ok, worker} = Worker.start_link(pool_name: parent)

      task = fn ->
        send(parent, :task_started)
        Process.sleep(10)
        send(parent, :task_completed)
      end

      Worker.execute(worker, task)

      assert_receive :task_started
      assert_receive :task_completed
      assert_receive {:worker_done, ^worker}
    end

    test "handles task failures gracefully" do
      parent = self()

      {:ok, worker} = Worker.start_link(pool_name: parent)

      failing_task = fn ->
        raise "Intentional error"
      end

      Worker.execute(worker, failing_task)

      # Should still notify pool even though task failed
      assert_receive {:worker_done, ^worker}, 1000

      # Worker should still be alive
      assert Process.alive?(worker)
    end

    test "handles task exits gracefully" do
      parent = self()

      {:ok, worker} = Worker.start_link(pool_name: parent)

      exiting_task = fn ->
        exit(:intentional_exit)
      end

      Worker.execute(worker, exiting_task)

      # Should still notify pool
      assert_receive {:worker_done, ^worker}, 1000

      # Worker should still be alive
      assert Process.alive?(worker)
    end

    test "can execute multiple tasks sequentially" do
      parent = self()

      {:ok, worker} = Worker.start_link(pool_name: parent)

      for i <- 1..3 do
        task = fn ->
          send(parent, {:task, i})
        end

        Worker.execute(worker, task)

        assert_receive {:task, ^i}
        assert_receive {:worker_done, ^worker}
      end

      assert Process.alive?(worker)
    end
  end

  describe "circuit breaker" do
    test "opens after threshold failures and rejects subsequent tasks" do
      Application.put_env(:phoenix_gen_api, :worker_pool,
        circuit_breaker_threshold: 1,
        circuit_breaker_cooldown: 60_000
      )

      on_exit(fn ->
        Application.delete_env(:phoenix_gen_api, :worker_pool)
      end)

      parent = self()
      {:ok, worker} = Worker.start_link(pool_name: parent)

      Worker.execute(worker, fn -> raise "boom" end)
      assert_receive {:worker_done, ^worker}, 1000

      Worker.execute(worker, fn -> send(parent, :should_not_run) end)
      assert_receive {:worker_done, ^worker}, 1000
      refute_receive :should_not_run, 100

      assert Process.alive?(worker)
    end

    test "closes the circuit after cooldown and resets on success" do
      Application.put_env(:phoenix_gen_api, :worker_pool,
        circuit_breaker_threshold: 1,
        circuit_breaker_cooldown: 0
      )

      on_exit(fn ->
        Application.delete_env(:phoenix_gen_api, :worker_pool)
      end)

      parent = self()
      {:ok, worker} = Worker.start_link(pool_name: parent)

      Worker.execute(worker, fn -> raise "boom" end)
      assert_receive {:worker_done, ^worker}, 1000

      Worker.execute(worker, fn -> send(parent, :ran_after_cooldown) end)
      assert_receive :ran_after_cooldown, 1000
      assert_receive {:worker_done, ^worker}, 1000
    end
  end

  describe "timeout handling" do
    test "terminates a task that exceeds the task_timeout" do
      parent = self()
      {:ok, worker} = Worker.start_link(pool_name: parent, task_timeout: 50)

      Worker.execute(worker, fn ->
        Process.sleep(500)
        send(parent, :task_survived)
      end)

      assert_receive {:worker_done, ^worker}, 1000
      refute_receive :task_survived, 100
      assert Process.alive?(worker)
    end
  end

  describe "unknown messages" do
    test "ignores unknown messages" do
      parent = self()
      {:ok, worker} = Worker.start_link(pool_name: parent)
      send(worker, :some_unknown_message)
      Process.sleep(20)
      assert Process.alive?(worker)
    end
  end
end
