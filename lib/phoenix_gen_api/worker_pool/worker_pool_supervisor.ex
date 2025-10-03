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
        max_queue_size: 1000

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

    async_pool_size = Keyword.get(config, :async_pool_size, 100)
    stream_pool_size = Keyword.get(config, :stream_pool_size, 50)
    max_queue_size = Keyword.get(config, :max_queue_size, 1000)

    Logger.info(
      "Starting WorkerPoolSupervisor - async: #{async_pool_size}, stream: #{stream_pool_size}"
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
