import Config

# Configure PhoenixGenApi
config :phoenix_gen_api,
  # Set to true if this node only makes requests (doesn't serve)
  client_mode: false

# Push token for authenticating push requests from remote nodes.
# When set, push requests must include a matching `push_token` in the PushConfig.
# If not set (nil), push requests are accepted without token check (backward compatible).
# push_token: "your-secret-push-token"

# MFA allowlist — restricts which {module, function} pairs can be registered
# as function configurations. When set, only MFAs matching an entry are allowed.
# Module-level entries (atom) allow all functions in that module.
# Tuple entries ({module, function}) allow only the specific function.
# If not set (nil), all MFAs are allowed (backward compatible).
# The following modules are ALWAYS blocked unless explicitly allowed:
# :os, :file, :code, :erlang, :net, :rpc, :global, :inet
# mfa_allowlist: [
#   MyApp.UserService,
#   {MyApp.OrderService, :create_order}
# ]

# Configure worker pools for async and stream execution
config :phoenix_gen_api, :worker_pool,
  # Number of workers for async calls
  async_pool_size: 1000,
  # Number of workers for stream calls
  stream_pool_size: 500,
  # Maximum number of tasks to queue when all workers are busy
  max_queue_size: 10_000

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
#       args: [],
#       # Optional: version checking — skip full pull when version unchanged
#       version_module: "ExampleService",
#       version_function: "get_config_version",
#       version_args: []
#     }
#   ]

# Admin actions allowlist for dangerous runtime operations.
# By default (when not configured), all admin actions are denied (fail-closed).
# Uncomment and customize to enable specific actions:
#
# config :phoenix_gen_api, :admin_actions,
#   [:change_detail_error, :update_rate_limit_config, :push_config]
#
# Environment recommendations:
# - Development: enable all actions for convenience
# - Production: enable only what's needed

# Import environment specific config
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
