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
end
