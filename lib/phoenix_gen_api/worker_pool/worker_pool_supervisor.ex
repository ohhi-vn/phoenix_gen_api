defmodule PhoenixGenApi.WorkerPool.WorkerPoolSupervisor do
  @moduledoc """
  Supervisor for worker pools.

  This supervisor manages the async and stream worker pools based on
  application configuration. It ensures worker pools are restarted if
  they crash.

  ## Configuration

  Configure in `config.exs`:

      config :phoenix_gen_api, :worker_pool,
        async_pool_size: 100,
        stream_pool_size: 50,
        max_queue_size: 1000,
        circuit_breaker_threshold: 10,
        circuit_breaker_cooldown: 60_000

  ## Circuit Breaker

  The `circuit_breaker_threshold` and `circuit_breaker_cooldown` options
  control the circuit breaker behavior for both the pool and individual
  workers. See `WorkerPool` and `Worker` for details.

  ## Pool Types

  - **Async Pool** - For asynchronous request execution
  - **Stream Pool** - For streaming request execution

  Each pool can have different sizes based on your workload characteristics.
  """

  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:phoenix_gen_api, :worker_pool, [])

    async_pool_size = Keyword.get(config, :async_pool_size, 1000)
    stream_pool_size = Keyword.get(config, :stream_pool_size, 500)
    max_queue_size = Keyword.get(config, :max_queue_size, 10_000)

    Logger.info(
      "[WorkerPoolSupervisor] starting, async_pool_size: #{async_pool_size}, stream_pool_size: #{stream_pool_size}, max_queue_size: #{max_queue_size}"
    )

    children = [
      # Async worker pool
      Supervisor.child_spec(
        {PhoenixGenApi.WorkerPool,
         name: :async_pool, pool_size: async_pool_size, max_queue_size: max_queue_size},
        id: :async_pool
      ),

      # Stream worker pool
      Supervisor.child_spec(
        {PhoenixGenApi.WorkerPool,
         name: :stream_pool, pool_size: stream_pool_size, max_queue_size: max_queue_size},
        id: :stream_pool
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
