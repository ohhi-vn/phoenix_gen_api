defmodule PhoenixGenApi.InternalImpl do
  @moduledoc false

  # @lib Application.compile_env(:phoenix, :json_library, JSON)

  alias PhoenixGenApi.Structs.{Response}

  # use PhoenixGenApi.ImplHelper,
  #   encoder: Module.concat(@lib, Encoder),
  #   impl: [
  #     Response
  #   ]

  defmacro __using__(opts) do
    quote location: :keep, bind_quoted: [opts: opts] do
      use PhoenixGenApi.ImplHelper,
        encoder: Module.concat(Application.compile_env(:phoenix, :json_library, JSON), Encoder),
        impl: [
          Response
        ]
    end
  end
end
