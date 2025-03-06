defmodule PhoenixGenApi.Structs.ServiceConfig do
  @moduledoc """
  Node config struct.
  """
  alias __MODULE__

  @derive Nestru.Decoder
  defstruct [
    # service name
    :service,
    # list of string, node name.
    :nodes,
    # module on remote node.
    :module,
    # function of module.
    :function,
    # list, arguments for function.
    :args,
  ]

  def from_map(config = %{}) do
    Nestru.decode!(config, ServiceConfig)
  end

end
