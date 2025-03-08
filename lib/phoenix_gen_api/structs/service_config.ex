defmodule PhoenixGenApi.Structs.ServiceConfig do
  @moduledoc """
  Node config struct.
  """
  alias __MODULE__

  @typedoc "service config struct."

  @type t :: %__MODULE__{
    service: String.t(),
    nodes: list(String.t()),
    module: String.t(),
    function: String.t(),
    args: list()
  }

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
