import Config

# Configure PhoenixGenApi
config :phoenix_gen_api,
  # Set to true if this node only makes requests (doesn't serve)
  client_mode: false

# Print only warnings and errors during test
config :logger, level: :warn

# for test encoding Response
config :phoenix, :json_library, JSON
