import Config

# Configure PhoenixGenApi
config :phoenix_gen_api,
  # Set to true if this node only makes requests (doesn't serve)
  client_mode: false

# Configure worker pools for async and stream execution
config :phoenix_gen_api, :worker_pool,
  # Number of workers for async calls
  async_pool_size: 100,
  # Number of workers for stream calls
  stream_pool_size: 50,
  # Maximum number of tasks to queue when all workers are busy
  max_queue_size: 1000

# Configure config puller
# config :phoenix_gen_api, :gen_api,
#   pull_timeout: 5_000,
#   pull_interval: 30_000,
#   detail_error: false,
#   service_configs: [
#     %{
#       service: "example_service",
#       nodes: ["node1@hostname", "node2@hostname"],
#       module: "ExampleService",
#       function: "get_api_config",
#       args: []
#     }
#   ]

# Import environment specific config
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
